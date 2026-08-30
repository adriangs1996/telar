//! Client bootstrap: the platform adapter that opens the real terminal,
//! performs the runtime handshake, and drives the event loop that delegates
//! every event to a `Client` entrypoint.

const std = @import("std");
const core = @import("telar-core");
const graphics = @import("../graphics/root.zig");
const workspace_capability = @import("../workspace/root.zig");
const platform = @import("../platform/root.zig");
const kitty = graphics.kitty;
const multiplexer = workspace_capability.multiplexer;

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;

const Client = @import("client.zig");
const Options = Client.Options;
const rectSize = multiplexer.rectSize;

pub fn run(
    init: std.process.Init,
    connection: *core.transport.SocketChannel,
    options: Options,
) !u8 {
    const io = init.io;
    var heap = diagnostics.Heap.init(init.gpa);
    const gpa = heap.allocator();

    // `Client.init` adopts the configuration generation, plugin registry and
    // trust store carried by `options`; until it succeeds they are still this
    // function's to free.
    var options_owned = true;
    defer if (options_owned) {
        if (options.lua_generation) |generation| generation.deinit();
        if (options.plugin_registry) |registry| gpa.destroy(registry);
        if (options.trust_store) |store| gpa.destroy(store);
    };

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

    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();

    const host_platform_size = tty.size();
    const client = try Client.init(.{
        .gpa = gpa,
        .io = io,
        .connection = connection,
        .input_file = input_file,
        .writer = writer,
        .host_size = Client.terminalSize(&tty),
        .window_width_px = host_platform_size.width_px,
        .window_height_px = host_platform_size.height_px,
        .options = options,
    });
    options_owned = false;
    // Registered after `watcher`'s defer on purpose: deinit cancels the
    // select tasks — one of them waits on the watcher — before the watcher
    // itself is torn down.
    defer client.deinit();

    // Declared before the first pane opens, so every attachment the runtime
    // creates for this session already knows whether it may hand this client
    // shared memory names instead of pixel chunks.
    const configure_payload = try schema.encodeConfigureGraphics(client.send_buffer, .{
        .shared = kitty.clientSupportsSharedMemory(),
    });
    try connection.send(io, configure_payload);

    const runtime_state_payload = try schema.encodeRequestRuntimeState(client.send_buffer);
    try connection.send(io, runtime_state_payload);

    const open_payload = try schema.encodeOpenPane(client.send_buffer, .{
        .request_id = Client.initial_request_id,
        .size = rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
        .launch = .{
            .cwd = options.cwd,
            .arguments = options.arguments,
        },
    });
    try connection.send(io, open_payload);
    try client.requests.add(Client.initial_request_id, .{ .initial_open = .{} });

    try client.select.concurrent(.resized, Client.waitResize, .{ io, &watcher });
    try client.select.concurrent(.server, Client.receive, .{ io, connection, client.receive_buffer });
    try client.select.concurrent(.capability_timeout, Client.waitCapabilityTimeout, .{io});
    if (comptime diagnostics.enabled) {
        if (telemetry.available())
            try client.select.concurrent(.telemetry_tick, diagnostics.waitForTick, .{io});
    }
    try client.scheduleConfigReload();

    while (true) {
        const event = try client.select.await();
        const path = diagnostics.enter(clientEventPath(event));
        defer path.restore();
        switch (event) {
            .input => |result| if (try client.handleHostInput(result)) return 0,
            .input_timeout => |result| if (try client.handleInputTimeoutEvent(result)) return 0,
            .binding_timeout => |result| if (try client.handleBindingTimeoutEvent(result)) return 0,
            .capability_timeout => |result| try client.handleCapabilityTimeoutEvent(result),
            .resized => |result| try client.handleResizeEvent(result, &tty, &watcher),
            .server => |result| if (try client.handleServerEvent(result)) |status| return status,
            .sent => |result| try client.handleSentEvent(result),
            .draw => |result| try client.handleDrawEvent(result),
            .media_tick => |result| try client.handleMediaTickEvent(result),
            .sidebar_animation_tick => |result| try client.handleSidebarAnimationEvent(result),
            .notification_tick => |result| try client.handleNotificationTickEvent(result),
            .sound_played => |result| try client.handleSoundPlayedEvent(result),
            .telemetry_tick => |result| client.handleTelemetryTickEvent(result, &telemetry, heap.snapshot()),
            .telemetry_written => |result| client.handleTelemetryWrittenEvent(result, &telemetry),
            .config_reload => |result| try client.handleConfigReloadEvent(result),
            .plugin_result => |result| if (try client.handlePluginResultEvent(result)) return 0,
            .clipboard_image => |result| try client.handleClipboardImageEvent(result),
        }

        try client.observeModel();
    }
}

fn clientEventPath(event: Client.ClientEvent) diagnostics.Path {
    return switch (event) {
        .input,
        .input_timeout,
        .binding_timeout,
        .capability_timeout,
        .resized,
        .server,
        .sent,
        .draw,
        .sidebar_animation_tick,
        => .interactive,
        .media_tick, .clipboard_image => .media,
        .notification_tick,
        .sound_played,
        .telemetry_tick,
        .telemetry_written,
        .config_reload,
        .plugin_result,
        => .observation,
    };
}
