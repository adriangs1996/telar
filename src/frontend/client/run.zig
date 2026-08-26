//! Client bootstrap: the platform adapter that opens the real terminal,
//! performs the runtime handshake, and drives the event loop that delegates
//! every event to a `Client` entrypoint.

const std = @import("std");
const core = @import("telar-core");
const graphics = @import("../graphics/root.zig");
const presentation = @import("../presentation/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const client_outbox = @import("outbox.zig");
const client_telemetry = @import("telemetry.zig");
const client_view = @import("view.zig");
const lua_config = @import("../config/root.zig");
const platform = @import("../platform/root.zig");
const plugin_broker = @import("../plugins/root.zig");
const kitty = graphics.kitty;
const term = presentation.screen;
const tabs_mod = workspace_capability.tabs;
const multiplexer = workspace_capability.multiplexer;

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;

const Client = @import("client.zig");
const Options = Client.Options;
const ClientEvent = Client.ClientEvent;
const ClientMetrics = client_telemetry.Metrics;
const ConfigReloadState = Client.ConfigReloadState;
const NotificationTimer = Client.NotificationTimer;
const initial_request_id = Client.initial_request_id;
const buildInputRouter = Client.buildInputRouter;
const terminalSize = Client.terminalSize;
const rectSize = multiplexer.rectSize;
const waitResize = Client.waitResize;
const receive = Client.receive;
const waitCapabilityTimeout = Client.waitCapabilityTimeout;

pub fn run(
    init: std.process.Init,
    connection: *core.transport.SocketChannel,
    options: Options,
) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var lua_generation = options.lua_generation;
    defer if (lua_generation) |generation| generation.deinit();
    var plugin_registry = options.plugin_registry;
    defer if (plugin_registry) |registry| gpa.destroy(registry);
    var trust_store = options.trust_store;
    defer if (trust_store) |store| gpa.destroy(store);

    var telemetry_suffix_buffer: [64]u8 = undefined;
    const telemetry_suffix = std.fmt.bufPrint(
        &telemetry_suffix_buffer,
        "client-{d}",
        .{std.c.getpid()},
    ) catch "client";
    var telemetry = diagnostics.Sink.init(io, options.endpoint, telemetry_suffix);
    defer telemetry.deinit(io);

    var tty = platform.Tty.open() catch |err| {
        std.debug.print("telar needs a terminal: {s}\n", .{@errorName(err)});
        return err;
    };
    defer tty.deinit();
    // A panic aborts without running these defers; the crash path puts the
    // terminal back on its own.
    platform.installCrashRestore(&tty);

    const input_file = tty.readHandle();
    var tty_file = tty.writeHandle();
    var output_buffer: [512 * 1024]u8 = undefined;
    var output_writer = tty_file.writer(io, &output_buffer);
    const writer = &output_writer.interface;

    try writer.writeAll(platform.enter_sequence);
    try writer.writeAll(kitty.capability_query);
    try writer.flush();
    defer {
        writer.writeAll(platform.leave_sequence) catch {};
        writer.flush() catch {};
    }

    var host_size = terminalSize(&tty);
    const host_platform_size = tty.size();
    var capabilities: kitty.TerminalCapabilities = .{
        .window_width_px = host_platform_size.width_px,
        .window_height_px = host_platform_size.height_px,
    };
    const initial_cell_size = capabilities.cellSize(host_size.cols, host_size.rows);
    host_size.cell_width_px = initial_cell_size.width;
    host_size.cell_height_px = initial_cell_size.height;
    var screen = try term.Screen.init(gpa, host_size.cols, host_size.rows);
    defer screen.deinit();
    var view = try client_view.State.initWithTheme(
        gpa,
        host_size.cols,
        host_size.rows,
        options.theme,
    );
    defer view.deinit();
    if (!options.sidebar_visible) view.toggleSidebar();
    try view.configureSidebar(
        options.sidebar_rendering,
        capabilities.kitty_graphics,
        initial_cell_size.width,
        initial_cell_size.height,
    );
    var tabs = tabs_mod.Model.init(gpa);
    defer tabs.deinit();
    tabs.setPaneGaps(options.pane_gaps);
    var graphics_store = if (options.host_shared_memory)
        kitty.Store.initSharedMemory(gpa)
    else
        kitty.Store.init(gpa);
    defer graphics_store.deinit();

    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    const send_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(send_buffer);

    // Declared before the first pane opens, so every attachment the runtime
    // creates for this session already knows whether it may hand this client
    // shared memory names instead of pixel chunks.
    const configure_payload = try schema.encodeConfigureGraphics(send_buffer, .{
        .shared = kitty.clientSupportsSharedMemory(),
    });
    try connection.send(io, configure_payload);

    const runtime_state_payload = try schema.encodeRequestRuntimeState(send_buffer);
    try connection.send(io, runtime_state_payload);

    const open_payload = try schema.encodeOpenPane(send_buffer, .{
        .request_id = initial_request_id,
        .size = rectSize(view.workbench()) orelse return error.TerminalTooSmall,
        .launch = .{
            .cwd = options.cwd,
            .arguments = options.arguments,
        },
    });
    try connection.send(io, open_payload);

    var reload_orphan: ?*lua_config.Generation = null;
    defer if (reload_orphan) |generation| generation.deinit();
    var reload_registry_orphan: ?*plugin_broker.Registry = null;
    defer if (reload_registry_orphan) |registry| gpa.destroy(registry);
    var reload_trust_orphan: ?*core.plugin.TrustStore = null;
    defer if (reload_trust_orphan) |store| gpa.destroy(store);
    const outbox = try gpa.create(client_outbox.Outbox);
    defer gpa.destroy(outbox);
    outbox.* = .{};
    var select_storage: [14]ClientEvent = undefined;
    var select = Io.Select(ClientEvent).init(io, &select_storage);
    defer select.cancelDiscard();
    try select.concurrent(.resized, waitResize, .{ io, &watcher });
    try select.concurrent(.server, receive, .{ io, connection, receive_buffer });
    try select.concurrent(.capability_timeout, waitCapabilityTimeout, .{io});
    if (comptime diagnostics.enabled) {
        if (telemetry.available())
            try select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{io});
    }

    var input_router = try buildInputRouter(options.prefix, options.bindings);
    input_router.escape_timeout_ns = options.input_escape_timeout_ns;
    input_router.sequence_timeout_ns = options.input_sequence_timeout_ns;
    var input_timeout_pending = false;
    var binding_timeout_pending = false;
    var telemetry_buffer: [4096]u8 = undefined;
    var telemetry_write_pending = false;
    var metrics: ClientMetrics = .{ .started_ns = diagnostics.now(io) };
    var notification_timer: NotificationTimer = .{};
    var client: Client = .{
        .io = io,
        .gpa = gpa,
        .connection = connection,
        .send_buffer = send_buffer,
        .outbox = outbox,
        .writer = writer,
        .select = &select,
        .options = &options,
        .metrics = &metrics,
        .screen = &screen,
        .view = &view,
        .tabs = &tabs,
        .graphics_store = &graphics_store,
        .capabilities = &capabilities,
        .input_file = input_file,
        .lua_generation = &lua_generation,
        .plugin_registry = &plugin_registry,
        .trust_store = &trust_store,
        .sidebar_rendering = options.sidebar_rendering,
        .config_mtime_ns = options.config_mtime_ns,
        .notification_timer = &notification_timer,
    };
    try client.requests.add(initial_request_id, .initial_open);
    const config_reload_state: ConfigReloadState = .{
        .router = &input_router,
        .host_size = &host_size,
        .generation_orphan = &reload_orphan,
        .registry_orphan = &reload_registry_orphan,
        .trust_orphan = &reload_trust_orphan,
    };
    try client.scheduleConfigReload(config_reload_state);

    while (true) switch (try select.await()) {
        .input => |result| if (try client.handleHostInput(
            &input_router,
            result,
            &input_timeout_pending,
            &binding_timeout_pending,
        )) return 0,
        .input_timeout => |result| if (try client.handleInputTimeoutEvent(
            result,
            &input_router,
            &input_timeout_pending,
            &binding_timeout_pending,
        )) return 0,
        .binding_timeout => |result| if (try client.handleBindingTimeoutEvent(
            result,
            &input_router,
            &input_timeout_pending,
            &binding_timeout_pending,
        )) return 0,
        .capability_timeout => |result| try client.handleCapabilityTimeoutEvent(
            result,
            host_size,
        ),
        .resized => |result| try client.handleResizeEvent(
            result,
            &tty,
            &watcher,
            &host_size,
        ),
        .server => |result| if (try client.handleServerEvent(result, receive_buffer)) |status|
            return status,
        .sent => |result| try client.handleSentEvent(result),
        .draw => |result| try client.handleDrawEvent(result),
        .sidebar_animation_tick => |result| try client.handleSidebarAnimationEvent(result),
        .notification_tick => |result| try client.handleNotificationTickEvent(result),
        .telemetry_tick => |result| client.handleTelemetryTickEvent(
            result,
            &telemetry,
            &telemetry_buffer,
            &telemetry_write_pending,
        ),
        .telemetry_written => |result| client.handleTelemetryWrittenEvent(
            result,
            &telemetry,
            &telemetry_write_pending,
        ),
        .config_reload => |result| try client.handleConfigReloadEvent(
            result,
            config_reload_state,
        ),
        .plugin_result => |result| if (try client.handlePluginResultEvent(result)) return 0,
    };
}
