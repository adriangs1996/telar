//! Disposable single-pane client for protocol version 1.

const std = @import("std");
const core = @import("telar-core");
const pace = @import("pace.zig");
const platform = @import("platform.zig");
const term = @import("term.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema.v1;

const input_chunk_size = 4096;

pub const Options = struct {
    arguments: []const []const u8,
    cwd: []const u8,
};

const InputChunk = struct {
    bytes: [input_chunk_size]u8 = undefined,
    len: u16 = 0,

    fn slice(chunk: *const InputChunk) []const u8 {
        return chunk.bytes[0..chunk.len];
    }
};

const ClientEvent = union(enum) {
    input: anyerror!InputChunk,
    resized: anyerror!void,
    server: anyerror![]u8,
    draw: anyerror!void,
};

pub fn run(
    init: std.process.Init,
    connection: *core.transport.SocketChannel,
    options: Options,
) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var tty = platform.Tty.open() catch |err| {
        std.debug.print("telar needs a terminal: {s}\n", .{@errorName(err)});
        return err;
    };
    defer tty.deinit();

    var tty_file = tty.writeHandle();
    var output_buffer: [512 * 1024]u8 = undefined;
    var output_writer = tty_file.writer(io, &output_buffer);
    const writer = &output_writer.interface;

    try writer.writeAll(platform.pane_enter_sequence);
    try writer.flush();
    defer {
        writer.writeAll(platform.pane_leave_sequence) catch {};
        writer.flush() catch {};
    }

    const initial_size = terminalSize(&tty);
    var screen = try term.Screen.init(gpa, initial_size.cols, initial_size.rows);
    defer screen.deinit();

    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    const send_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(send_buffer);

    const open_payload = try schema.encodeOpenPane(send_buffer, .{
        .request_id = 1,
        .size = initial_size,
        .launch = .{
            .cwd = options.cwd,
            .arguments = options.arguments,
        },
    });
    try connection.send(io, open_payload);

    var select_storage: [4]ClientEvent = undefined;
    var select = Io.Select(ClientEvent).init(io, &select_storage);
    defer select.cancelDiscard();
    try select.concurrent(.resized, waitResize, .{ io, &watcher });
    try select.concurrent(.server, receive, .{ io, connection, receive_buffer });

    var pane_id: u64 = 0;
    var applied_frame_id: u64 = 0;
    var input_started = false;
    var draw_pending = false;
    var pending_updates: usize = 0;
    var pacer: pace.Pacer = .{};
    while (true) switch (try select.await()) {
        .input => |result| {
            const chunk = try result;
            if (chunk.len == 0) return 0;
            if (pane_id != 0) {
                const payload = try schema.encodePaneInput(send_buffer, .{
                    .pane_id = pane_id,
                    .bytes = chunk.slice(),
                });
                try connection.send(io, payload);
            }
            try select.concurrent(.input, readInput, .{io});
        },
        .resized => |result| {
            try result;
            if (pane_id != 0) {
                const payload = try schema.encodePaneResize(send_buffer, .{
                    .pane_id = pane_id,
                    .size = terminalSize(&tty),
                });
                try connection.send(io, payload);
            }
            try select.concurrent(.resized, waitResize, .{ io, &watcher });
        },
        .server => |result| {
            const payload = try result;
            switch (try schema.decodeServer(payload)) {
                .pane_opened => |opened| {
                    pane_id = opened.pane_id;
                    if (!input_started) {
                        try select.concurrent(.input, readInput, .{io});
                        input_started = true;
                    }
                },
                .pane_frame => |frame| {
                    if (pane_id == 0 or frame.pane_id != pane_id)
                        return error.UnexpectedPane;
                    if (frame.base_frame_id != 0 and frame.base_frame_id != applied_frame_id) {
                        const request = try schema.encodeRequestSnapshot(send_buffer, .{
                            .pane_id = pane_id,
                            .known_frame_id = applied_frame_id,
                        });
                        try connection.send(io, request);
                    } else {
                        try applyFrame(&screen, frame);
                        applied_frame_id = frame.frame_id;
                        const ack = try schema.encodeFrameAck(send_buffer, .{
                            .pane_id = pane_id,
                            .frame_id = applied_frame_id,
                        });
                        try connection.send(io, ack);
                        pending_updates += 1;
                        if (!draw_pending) {
                            const wait_ns = pacer.waitFor(monotonic(io));
                            if (wait_ns == 0) {
                                _ = try screen.flush(writer);
                                pacer.record(monotonic(io), pending_updates);
                                pending_updates = 0;
                            } else {
                                pacer.noteThrottled();
                                draw_pending = true;
                                try select.concurrent(.draw, waitToDraw, .{ io, wait_ns });
                            }
                        }
                    }
                },
                .pane_exited => |exited| {
                    if (exited.pane_id != pane_id) return error.UnexpectedPane;
                    if (pending_updates != 0) _ = try screen.flush(writer);
                    return exitCode(exited);
                },
                .request_failed => |failure| {
                    std.debug.print("telar runtime: {s}\n", .{failure.message});
                    return error.RuntimeRequestFailed;
                },
                .runtime_stopping => return error.UnexpectedRuntimeShutdown,
            }
            try select.concurrent(.server, receive, .{ io, connection, receive_buffer });
        },
        .draw => |result| {
            try result;
            draw_pending = false;
            if (pending_updates != 0) {
                _ = try screen.flush(writer);
                pacer.record(monotonic(io), pending_updates);
                pending_updates = 0;
            }
        },
    };
}

fn applyFrame(screen: *term.Screen, frame: schema.frame.FrameView) !void {
    if (frame.base_frame_id == 0 and
        (screen.buffer().w != frame.cols or screen.buffer().h != frame.rows))
    {
        try screen.resize(frame.cols, frame.rows);
    } else if (screen.buffer().w != frame.cols or screen.buffer().h != frame.rows) {
        return error.PatchSizeMismatch;
    }

    var spans = frame.spans();
    while (spans.next()) |span| {
        var cells = span.cells();
        var index: usize = span.start;
        while (cells.next()) |cell| : (index += 1) {
            screen.buffer().cells[index] = cell;
        }
    }
    screen.cursor = if (frame.cursor.visible)
        .{ .x = frame.cursor.x, .y = frame.cursor.y }
    else
        null;
}

fn readInput(io: Io) anyerror!InputChunk {
    var chunk: InputChunk = .{};
    chunk.len = @intCast(try File.stdin().readStreaming(io, &.{&chunk.bytes}));
    return chunk;
}

fn waitResize(io: Io, watcher: *platform.ResizeWatcher) anyerror!void {
    return watcher.wait(io);
}

fn receive(
    io: Io,
    connection: *core.transport.SocketChannel,
    buffer: []u8,
) anyerror![]u8 {
    return connection.receive(io, buffer);
}

fn waitToDraw(io: Io, nanoseconds: u64) anyerror!void {
    try io.sleep(.fromNanoseconds(@intCast(nanoseconds)), .awake);
}

fn monotonic(io: Io) u64 {
    const timestamp = Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

fn terminalSize(tty: *const platform.Tty) schema.TerminalSize {
    const size = tty.size();
    return .{
        .cols = if (size.cols == 0) 80 else size.cols,
        .rows = if (size.rows == 0) 24 else size.rows,
    };
}

fn exitCode(message: schema.PaneExited) u8 {
    return switch (message.kind) {
        .exited => @intCast(@min(message.value, std.math.maxInt(u8))),
        .signaled => @intCast(@min(128 + message.value, std.math.maxInt(u8))),
    };
}

test "signal exits use the shell status convention" {
    try std.testing.expectEqual(@as(u8, 137), exitCode(.{
        .pane_id = 1,
        .kind = .signaled,
        .value = 9,
    }));
}
