//! Client process adapter: opens the real terminal, constructs and starts one
//! client, then lends each completed event to the dispatcher.

const TerminalClient = @import("TerminalClient.zig");
const std = @import("std");
const SocketChannelType = @import("telar-core").SocketChannel;
const Options = @import("telar-client").Options;
const HeapType = @import("telar-core").Heap;
const platform = @import("../platform/platform.zig");
const sequences = @import("../platform/sequences.zig");
const Client = @import("telar-client").AttachedClient;
const host_resizes = @import("controllers/host/host_resizes.zig");
const client_startup = @import("controllers/session/client_startup.zig");
const client_events = @import("entrypoints/events.zig");
const ClientIdentityType = @import("telar-core").ClientIdentity;

pub fn run(init: std.process.Init, connection: *SocketChannelType, options: Options) !u8 {
    const io = init.io;
    var heap = HeapType.init(init.gpa);
    const gpa = heap.allocator();

    // `Client.init` adopts the configuration generation, plugin registry and
    // trust store carried by `options`; until it succeeds they are still this
    // function's to free.
    var options_owned = true;
    defer if (options_owned) {
        if (options.lua_generation) |generation| {
            generation.deinit();
        }
        if (options.plugin_registry) |registry| {
            gpa.destroy(registry);
        }
        if (options.trust_store) |store| {
            gpa.destroy(store);
        }
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

    try writer.writeAll(sequences.enter);
    try writer.flush();
    defer {
        writer.writeAll(sequences.leave) catch {};
        writer.flush() catch {};
    }

    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();

    var fast_output = platform.FastWriter.open();
    defer if (fast_output) |*fast| {
        fast.deinit();
    };

    const host_platform_size = tty.size();
    const terminal = try TerminalClient.init(.{
        .gpa = gpa,
        .io = io,
        .connection = connection,
        .input_file = input_file,
        .writer = writer,
        .async_output = true,
        .fast_output = if (fast_output) |*fast| .{ .context = fast, .write = platform.FastWriter.writeOpaque } else null,
        .host_size = host_resizes.initialSize(host_platform_size),
        .window_width_px = host_platform_size.width_px,
        .window_height_px = host_platform_size.height_px,
        .client_identity = try terminalIdentity(init.minimal.environ, &tty),
        .options = options,
    });
    options_owned = false;
    // Registered after `watcher`'s defer on purpose: deinit cancels the
    // select tasks — one of them waits on the watcher — before the watcher
    // itself is torn down.
    defer terminal.deinit();
    const client = &terminal.app;

    try client_startup.start(client, .{ .resize_watcher = &watcher });

    while (true) {
        const event = try terminal.select.await();
        switch (try client_events.handle(client, event, .{
            .tty = &tty,
            .resize_watcher = &watcher,
            .heap = &heap,
        })) {
            .keep_running => {},
            .exit => |status| return status,
        }
    }
}

fn terminalIdentity(environ: std.process.Environ, tty: *const platform.Tty) !ClientIdentityType {
    const keys = [_][]const u8{
        "TERM_SESSION_ID",
        "WT_SESSION",
        "KITTY_WINDOW_ID",
        "WEZTERM_PANE",
        "TMUX_PANE",
    };
    var hasher = std.hash.Wyhash.init(0x74656c61722d636c);
    var found = false;
    for (keys) |key| {
        const value = environ.getPosix(key) orelse continue;
        if (value.len == 0) {
            continue;
        }

        hasher.update(key);
        hasher.update(&.{0});
        hasher.update(value);
        hasher.update(&.{0});
        found = true;
    }
    if (found) {
        return @enumFromInt(hasher.final() | 1);
    }

    return @enumFromInt((try tty.identity()) | 1);
}
