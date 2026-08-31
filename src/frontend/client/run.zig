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
const diagnostics = core.diagnostics;
const sidebar_animations = @import("sidebar_animations.zig");

const Client = @import("client.zig");
const agent_sounds = @import("agent_sounds.zig");
const client_telemetry = @import("telemetry.zig");
const host_inputs = @import("host_inputs.zig");
const host_resizes = @import("host_resizes.zig");
const notification_flow = @import("notifications.zig");
const request_lifecycle = @import("request_lifecycle.zig");
const runtime_transport = @import("runtime_transport.zig");
const Options = Client.Options;
const rectSize = multiplexer.rectSize;

pub fn run(init: std.process.Init, connection: *core.transport.SocketChannel, options: Options) !u8 {
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
        .host_size = host_resizes.initialSize(host_platform_size),
        .window_width_px = host_platform_size.width_px,
        .window_height_px = host_platform_size.height_px,
        .options = options,
    });
    options_owned = false;
    // Registered after `watcher`'s defer on purpose: deinit cancels the
    // select tasks — one of them waits on the watcher — before the watcher
    // itself is torn down.
    defer client.deinit();

    const initial_request_id = try request_lifecycle.registerInitial(client);
    try client.runtime_transport.bootstrap(io, .{
        .graphics_shared = kitty.clientSupportsSharedMemory(),
        .open = .{
            .request_id = initial_request_id,
            .size = rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
            .launch = .{
                .cwd = options.cwd,
                .arguments = options.arguments,
            },
        },
    });

    try client.select.concurrent(.resized, Client.waitResize, .{ io, &watcher });
    try runtime_transport.scheduleRead(client);
    try client.select.concurrent(.capability_timeout, Client.waitCapabilityTimeout, .{io});
    try client_telemetry.start(client);
    try client.scheduleConfigReload();

    while (true) {
        const event = try client.select.await();
        const path = diagnostics.enter(clientEventPath(event));
        defer path.restore();
        switch (event) {
            .input => |result| if (try host_inputs.handleRead(client, result)) return 0,
            .input_timeout => |result| if (try host_inputs.handleInputTimeout(client, result)) return 0,
            .binding_timeout => |result| if (try host_inputs.handleBindingTimeout(client, result)) return 0,
            .capability_timeout => |result| try client.handleCapabilityTimeoutEvent(result),
            .resized => |result| try client.handleResizeEvent(result, .{
                .tty = &tty,
                .watcher = &watcher,
            }),
            .server => |result| if (try runtime_transport.handleRead(client, result)) |status| return status,
            .sent => |result| try runtime_transport.handleSent(client, result),
            .draw => |result| try client.handleDrawEvent(result),
            .media_tick => |result| try client.handleMediaTickEvent(result),
            .sidebar_animation_tick => |result| _ = try sidebar_animations.handleTick(client, result),
            .notification_tick => |result| _ = try notification_flow.handleTick(client, result),
            .sound_played => |result| try agent_sounds.handlePlayed(client, result),
            .telemetry_tick => |result| client_telemetry.handleTick(client, result, heap.snapshot()),
            .telemetry_written => |result| client_telemetry.handleWritten(client, result),
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
