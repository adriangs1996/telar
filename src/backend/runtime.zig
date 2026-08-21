//! Long-lived single-pane runtime for protocol version 1.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const blit = @import("blit.zig");
const pty = @import("pty.zig");
const transport = @import("transport.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema.v1;
const output_chunk_size = 16 * 1024;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const Output = struct {
    bytes: [output_chunk_size]u8 = undefined,
    len: u16 = 0,

    fn slice(output: *const Output) []const u8 {
        return output.bytes[0..output.len];
    }
};

const RuntimeEvent = union(enum) {
    accepted: anyerror!core.transport.SocketChannel,
    client_message: anyerror![]u8,
    client_sent: anyerror!void,
    pane_input_written: anyerror!void,
    pane_output: anyerror!Output,
    pane_exit: anyerror!pty.Exit,
    stopped: anyerror!void,
};

const PendingFailure = struct {
    request_id: u64,
    code: schema.FailureCode,
    message: []const u8,
};

const OwnedCommand = struct {
    command: pty.Command,
    arguments: []const [:0]u8,
    cwd: [:0]u8,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, launch: schema.LaunchView) !OwnedCommand {
        if (launch.environment_mode != .inherit_runtime or launch.environment_count != 0)
            return error.UnsupportedEnvironment;

        const arguments = try gpa.alloc([:0]u8, launch.argument_count);
        errdefer gpa.free(arguments);
        var initialized: usize = 0;
        errdefer for (arguments[0..initialized]) |argument| gpa.free(argument);

        var iterator = launch.arguments();
        while (iterator.next()) |argument| {
            arguments[initialized] = try gpa.dupeZ(u8, argument);
            initialized += 1;
        }
        const cwd = try gpa.dupeZ(u8, launch.cwd);
        errdefer gpa.free(cwd);

        var command: pty.Command = .{ .file = arguments[0].ptr, .cwd = cwd.ptr };
        for (arguments, 0..) |argument, index| command.argv[index] = argument.ptr;
        return .{ .command = command, .arguments = arguments, .cwd = cwd, .gpa = gpa };
    }

    fn deinit(command: *OwnedCommand) void {
        for (command.arguments) |argument| command.gpa.free(argument);
        command.gpa.free(command.arguments);
        command.gpa.free(command.cwd);
    }
};

const Pane = struct {
    id: u64,
    session: pty.Session,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    render_state: vt.RenderState = .empty,
    screen: core.ui.Buffer,
    acknowledged: core.ui.Buffer,
    cursor: schema.frame.Cursor = .{},
    next_frame_id: u64 = 1,
    acknowledged_frame_id: u64 = 0,
    outstanding_frame_id: u64 = 0,
    dirty: bool = true,
    output_pending: bool = false,
    output_done: bool = false,
    wait_pending: bool = false,
    exit: ?pty.Exit = null,
    gpa: std.mem.Allocator,

    fn create(
        io: Io,
        gpa: std.mem.Allocator,
        id: u64,
        command: *const pty.Command,
        size: schema.TerminalSize,
    ) !*Pane {
        const pane = try gpa.create(Pane);
        errdefer gpa.destroy(pane);

        pane.id = id;
        pane.gpa = gpa;
        pane.session = try .spawn(command, .{ .cols = size.cols, .rows = size.rows });
        errdefer pane.session.deinit();
        pane.terminal = try .init(io, gpa, .{ .cols = size.cols, .rows = size.rows });
        errdefer pane.terminal.deinit(gpa);
        pane.stream = pane.terminal.vtStream();
        errdefer pane.stream.deinit();
        pane.render_state = .empty;
        pane.screen = try .init(gpa, size.cols, size.rows);
        errdefer pane.screen.deinit();
        pane.acknowledged = try .init(gpa, size.cols, size.rows);
        errdefer pane.acknowledged.deinit();
        pane.cursor = .{};
        pane.next_frame_id = 1;
        pane.acknowledged_frame_id = 0;
        pane.outstanding_frame_id = 0;
        pane.dirty = true;
        pane.output_pending = false;
        pane.output_done = false;
        pane.wait_pending = false;
        pane.exit = null;
        try pane.render(true);
        return pane;
    }

    fn destroy(pane: *Pane) void {
        const gpa = pane.gpa;
        pane.acknowledged.deinit();
        pane.screen.deinit();
        pane.render_state.deinit(gpa);
        pane.stream.deinit();
        pane.terminal.deinit(gpa);
        pane.session.deinit();
        gpa.destroy(pane);
    }

    fn ingest(pane: *Pane, bytes: []const u8) !void {
        pane.stream.nextSlice(bytes);
        pane.dirty = true;
    }

    fn resize(pane: *Pane, size: schema.TerminalSize) !void {
        if (pane.screen.w == size.cols and pane.screen.h == size.rows) return;
        try pane.session.resize(.{ .cols = size.cols, .rows = size.rows });
        try pane.terminal.resize(pane.gpa, .{ .cols = size.cols, .rows = size.rows });
        try pane.screen.resize(size.cols, size.rows);
        try pane.acknowledged.resize(size.cols, size.rows);
        pane.outstanding_frame_id = 0;
        try pane.render(true);
    }

    fn render(pane: *Pane, force: bool) !void {
        try pane.render_state.update(pane.gpa, &pane.terminal);
        _ = blit.blit(&pane.screen, pane.screen.area(), &pane.render_state, .{ .force = force });
        const cursor = pane.render_state.cursor;
        pane.cursor = if (cursor.visible and cursor.viewport != null and
            cursor.viewport.?.x < pane.screen.w and cursor.viewport.?.y < pane.screen.h)
            .{ .visible = true, .x = cursor.viewport.?.x, .y = cursor.viewport.?.y }
        else
            .{};
        pane.dirty = true;
    }
};

pub fn serve(io: Io, gpa: std.mem.Allocator, endpoint: []const u8) !void {
    return serveInternal(io, gpa, endpoint, null);
}

/// Test seam for stopping an otherwise long-lived runtime without signals.
pub fn serveUntil(
    io: Io,
    gpa: std.mem.Allocator,
    endpoint: []const u8,
    stop: *Io.Queue(u8),
) !void {
    return serveInternal(io, gpa, endpoint, stop);
}

fn serveInternal(
    io: Io,
    gpa: std.mem.Allocator,
    endpoint: []const u8,
    stop: ?*Io.Queue(u8),
) !void {
    _ = setenv("TERM", "xterm-256color", 1);
    _ = setenv("TERM_PROGRAM", "telar", 1);

    var listener = try transport.local.LocalListener.listen(io, endpoint);

    const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(receive_buffer);
    const send_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
    defer gpa.free(send_buffer);
    const input_buffer = try gpa.alloc(u8, schema.max_input_bytes);
    defer gpa.free(input_buffer);

    var select_storage: [9]RuntimeEvent = undefined;
    var select = Io.Select(RuntimeEvent).init(io, &select_storage);
    try select.concurrent(.accepted, acceptClient, .{ io, &listener });
    if (stop) |queue| try select.concurrent(.stopped, waitForStop, .{ io, queue });

    var connection: ?core.transport.SocketChannel = null;
    var client_read_pending = false;
    var client_send_pending = false;
    var pane_input_pending = false;
    var attached_pane_id: u64 = 0;
    var exit_sent = false;
    var pending_opened: ?schema.PaneOpened = null;
    var pending_failure: ?PendingFailure = null;
    var snapshot_pending = false;
    var pane: ?*Pane = null;
    var next_pane_id: u64 = 1;
    defer {
        listener.deinit(io);
        if (connection) |*active| active.deinit(io);
        select.cancelDiscard();
        if (pane) |active| active.destroy();
    }

    while (true) switch (try select.await()) {
        .stopped => |result| return result,
        .accepted => |result| {
            var accepted = result catch {
                try select.concurrent(.accepted, acceptClient, .{ io, &listener });
                continue;
            };
            try select.concurrent(.accepted, acceptClient, .{ io, &listener });
            if (connection != null or pane_input_pending) {
                accepted.deinit(io);
                continue;
            }
            connection = accepted;
            pending_opened = null;
            pending_failure = null;
            snapshot_pending = false;
            client_read_pending = true;
            try select.concurrent(.client_message, receiveClient, .{
                io,
                &connection.?,
                receive_buffer,
            });
        },
        .client_message => |result| {
            client_read_pending = false;
            const payload = result catch {
                connection.?.deinit(io);
                if (!client_send_pending) connection = null;
                attached_pane_id = 0;
                exit_sent = false;
                pending_opened = null;
                pending_failure = null;
                snapshot_pending = false;
                continue;
            };
            const message = schema.decodeClient(payload) catch {
                connection.?.deinit(io);
                if (!client_send_pending) connection = null;
                attached_pane_id = 0;
                exit_sent = false;
                continue;
            };
            dispatchClientMessage(
                io,
                gpa,
                &select,
                message,
                &pane,
                &next_pane_id,
                &attached_pane_id,
                &exit_sent,
                &pending_opened,
                &pending_failure,
                &snapshot_pending,
                input_buffer,
                &pane_input_pending,
            ) catch {
                connection.?.deinit(io);
                if (!client_send_pending) connection = null;
                attached_pane_id = 0;
                exit_sent = false;
                continue;
            };
            pumpSend(
                io,
                &select,
                connectionPointer(&connection),
                send_buffer,
                pane,
                attached_pane_id,
                &client_send_pending,
                &pending_opened,
                &pending_failure,
                &snapshot_pending,
                &exit_sent,
            ) catch {
                closeClient(
                    io,
                    &connection,
                    client_read_pending,
                    client_send_pending,
                    &attached_pane_id,
                    &exit_sent,
                );
                continue;
            };
            if (!pane_input_pending) {
                client_read_pending = true;
                try select.concurrent(.client_message, receiveClient, .{
                    io,
                    &connection.?,
                    receive_buffer,
                });
            }
        },
        .client_sent => |result| {
            client_send_pending = false;
            result catch {
                closeClient(
                    io,
                    &connection,
                    client_read_pending,
                    client_send_pending,
                    &attached_pane_id,
                    &exit_sent,
                );
                continue;
            };
            if (connection == null or !connection.?.active) {
                if (!client_read_pending) connection = null;
                continue;
            }
            pumpSend(
                io,
                &select,
                connectionPointer(&connection),
                send_buffer,
                pane,
                attached_pane_id,
                &client_send_pending,
                &pending_opened,
                &pending_failure,
                &snapshot_pending,
                &exit_sent,
            ) catch {
                closeClient(
                    io,
                    &connection,
                    client_read_pending,
                    client_send_pending,
                    &attached_pane_id,
                    &exit_sent,
                );
            };
        },
        .pane_input_written => |result| {
            pane_input_pending = false;
            result catch {
                closeClient(
                    io,
                    &connection,
                    client_read_pending,
                    client_send_pending,
                    &attached_pane_id,
                    &exit_sent,
                );
                continue;
            };
            if (connectionPointer(&connection) != null and !client_read_pending) {
                client_read_pending = true;
                try select.concurrent(.client_message, receiveClient, .{
                    io,
                    &connection.?,
                    receive_buffer,
                });
            }
        },
        .pane_output => |result| {
            const active = pane orelse continue;
            active.output_pending = false;
            const output = result catch {
                active.output_done = true;
                pumpSend(io, &select, connectionPointer(&connection), send_buffer, pane, attached_pane_id, &client_send_pending, &pending_opened, &pending_failure, &snapshot_pending, &exit_sent) catch {
                    closeClient(io, &connection, client_read_pending, client_send_pending, &attached_pane_id, &exit_sent);
                };
                continue;
            };
            if (output.len == 0) {
                active.output_done = true;
            } else {
                try active.ingest(output.slice());
                active.output_pending = true;
                try select.concurrent(.pane_output, readPane, .{ io, active.session.file() });
            }
            pumpSend(io, &select, connectionPointer(&connection), send_buffer, pane, attached_pane_id, &client_send_pending, &pending_opened, &pending_failure, &snapshot_pending, &exit_sent) catch {
                closeClient(io, &connection, client_read_pending, client_send_pending, &attached_pane_id, &exit_sent);
            };
        },
        .pane_exit => |result| {
            const active = pane orelse continue;
            active.wait_pending = false;
            active.exit = try result;
            pumpSend(io, &select, connectionPointer(&connection), send_buffer, pane, attached_pane_id, &client_send_pending, &pending_opened, &pending_failure, &snapshot_pending, &exit_sent) catch {
                closeClient(io, &connection, client_read_pending, client_send_pending, &attached_pane_id, &exit_sent);
            };
        },
    };
}

fn dispatchClientMessage(
    io: Io,
    gpa: std.mem.Allocator,
    select: *Io.Select(RuntimeEvent),
    message: schema.ClientMessage,
    pane_slot: *?*Pane,
    next_pane_id: *u64,
    attached_pane_id: *u64,
    exit_sent: *bool,
    pending_opened: *?schema.PaneOpened,
    pending_failure: *?PendingFailure,
    snapshot_pending: *bool,
    input_buffer: []u8,
    input_pending: *bool,
) !void {
    switch (message) {
        .open_pane => |open| {
            var created = false;
            const active = switch (open.target) {
                .pane => |wanted| pane: {
                    const existing = pane_slot.* orelse {
                        pending_failure.* = .{ .request_id = open.request_id, .code = .pane_not_found, .message = "pane not found" };
                        return;
                    };
                    if (existing.id != wanted) {
                        pending_failure.* = .{ .request_id = open.request_id, .code = .pane_not_found, .message = "pane not found" };
                        return;
                    }
                    break :pane existing;
                },
                .default => pane: {
                    if (pane_slot.*) |existing| {
                        if (existing.exit != null and existing.output_done) {
                            existing.destroy();
                            pane_slot.* = null;
                        } else break :pane existing;
                    }

                    const launch = open.launch.?;
                    var command = OwnedCommand.init(gpa, launch) catch {
                        pending_failure.* = .{ .request_id = open.request_id, .code = .invalid_request, .message = "unsupported launch environment" };
                        return;
                    };
                    defer command.deinit();
                    const fresh = Pane.create(io, gpa, next_pane_id.*, &command.command, open.size) catch {
                        pending_failure.* = .{ .request_id = open.request_id, .code = .spawn_failed, .message = "could not start pane process" };
                        return;
                    };
                    next_pane_id.* += 1;
                    pane_slot.* = fresh;
                    fresh.output_pending = true;
                    fresh.wait_pending = true;
                    try select.concurrent(.pane_output, readPane, .{ io, fresh.session.file() });
                    try select.concurrent(.pane_exit, waitPane, .{fresh});
                    created = true;
                    break :pane fresh;
                },
            };

            attached_pane_id.* = active.id;
            exit_sent.* = false;
            pending_opened.* = .{
                .request_id = open.request_id,
                .pane_id = active.id,
                .created = created,
            };
            try active.resize(open.size);
            snapshot_pending.* = true;
        },
        .pane_input => |input| {
            const active = try attachedPane(pane_slot.*, attached_pane_id.*, input.pane_id);
            if (active.exit != null) return;
            std.debug.assert(!input_pending.*);
            @memcpy(input_buffer[0..input.bytes.len], input.bytes);
            input_pending.* = true;
            select.concurrent(.pane_input_written, writePaneInput, .{
                io,
                active.session.file(),
                input_buffer[0..input.bytes.len],
            }) catch |err| {
                input_pending.* = false;
                return err;
            };
        },
        .pane_resize => |resize| {
            const active = try attachedPane(pane_slot.*, attached_pane_id.*, resize.pane_id);
            try active.resize(resize.size);
            snapshot_pending.* = true;
        },
        .frame_ack => |ack| {
            const active = try attachedPane(pane_slot.*, attached_pane_id.*, ack.pane_id);
            if (ack.frame_id != active.outstanding_frame_id) return;
            active.acknowledged_frame_id = ack.frame_id;
            active.outstanding_frame_id = 0;
        },
        .request_snapshot => |request| {
            _ = try attachedPane(pane_slot.*, attached_pane_id.*, request.pane_id);
            snapshot_pending.* = true;
        },
        .detach_pane => |detach| {
            _ = try attachedPane(pane_slot.*, attached_pane_id.*, detach.pane_id);
            attached_pane_id.* = 0;
            exit_sent.* = false;
        },
    }
}

fn encodeFrame(
    buffer: []u8,
    pane: *Pane,
    force_snapshot: bool,
) ![]const u8 {
    if (pane.dirty) try pane.render(false);
    var span_storage: [schema.frame.max_span_count]schema.frame.Span = undefined;
    var span_count: usize = 0;
    var snapshot = force_snapshot;

    if (!snapshot) {
        var index: usize = 0;
        while (index < pane.screen.cells.len) {
            if (pane.screen.cells[index].eqlPublic(&pane.acknowledged.cells[index])) {
                index += 1;
                continue;
            }
            if (span_count == span_storage.len) {
                snapshot = true;
                break;
            }
            const start = index;
            while (index < pane.screen.cells.len and
                !pane.screen.cells[index].eqlPublic(&pane.acknowledged.cells[index]))
            {
                index += 1;
            }
            span_storage[span_count] = .{
                .start = @intCast(start),
                .cells = pane.screen.cells[start..index],
            };
            span_count += 1;
        }
    }
    if (snapshot) {
        span_storage[0] = .{ .start = 0, .cells = pane.screen.cells };
        span_count = 1;
    }

    const frame_id = pane.next_frame_id;
    pane.next_frame_id += 1;
    const payload = try schema.encodePaneFrame(buffer, .{
        .pane_id = pane.id,
        .frame_id = frame_id,
        .base_frame_id = if (snapshot) 0 else pane.acknowledged_frame_id,
        .cols = pane.screen.w,
        .rows = pane.screen.h,
        .cursor = pane.cursor,
        .spans = span_storage[0..span_count],
    });
    @memcpy(pane.acknowledged.cells, pane.screen.cells);
    pane.outstanding_frame_id = frame_id;
    pane.dirty = false;
    return payload;
}

fn pumpSend(
    io: Io,
    select: *Io.Select(RuntimeEvent),
    connection: ?*core.transport.SocketChannel,
    buffer: []u8,
    pane: ?*Pane,
    attached_pane_id: u64,
    send_pending: *bool,
    pending_opened: *?schema.PaneOpened,
    pending_failure: *?PendingFailure,
    snapshot_pending: *bool,
    exit_sent: *bool,
) !void {
    if (connection == null or send_pending.*) return;

    if (pending_failure.*) |failure| {
        const payload = try schema.encodeRequestFailed(buffer, .{
            .request_id = failure.request_id,
            .code = failure.code,
            .message = failure.message,
        });
        pending_failure.* = null;
        return startSend(io, select, connection.?, payload, send_pending);
    }
    if (pending_opened.*) |opened| {
        const payload = try schema.encodePaneOpened(buffer, opened);
        pending_opened.* = null;
        return startSend(io, select, connection.?, payload, send_pending);
    }

    const active = pane orelse return;
    if (attached_pane_id != active.id) return;
    if (snapshot_pending.*) {
        const payload = try encodeFrame(buffer, active, true);
        snapshot_pending.* = false;
        return startSend(io, select, connection.?, payload, send_pending);
    }
    if (active.outstanding_frame_id == 0 and active.dirty) {
        const payload = try encodeFrame(buffer, active, false);
        return startSend(io, select, connection.?, payload, send_pending);
    }
    if (exit_sent.* or !active.output_done or active.exit == null) return;
    if (active.outstanding_frame_id != 0) return;

    const exit = active.exit.?;
    const payload = try schema.encodePaneExited(buffer, .{
        .pane_id = active.id,
        .kind = switch (exit) {
            .exited => .exited,
            .signaled => .signaled,
        },
        .value = switch (exit) {
            .exited => |status| status,
            .signaled => |signal| @intFromEnum(signal),
        },
    });
    exit_sent.* = true;
    return startSend(io, select, connection.?, payload, send_pending);
}

fn startSend(
    io: Io,
    select: *Io.Select(RuntimeEvent),
    connection: *core.transport.SocketChannel,
    payload: []const u8,
    send_pending: *bool,
) !void {
    std.debug.assert(!send_pending.*);
    send_pending.* = true;
    select.concurrent(.client_sent, sendClient, .{ io, connection, payload }) catch |err| {
        send_pending.* = false;
        return err;
    };
}

fn connectionPointer(
    connection: *?core.transport.SocketChannel,
) ?*core.transport.SocketChannel {
    return if (connection.*) |*active| if (active.active) active else null else null;
}

fn closeClient(
    io: Io,
    connection: *?core.transport.SocketChannel,
    read_pending: bool,
    send_pending: bool,
    attached_pane_id: *u64,
    exit_sent: *bool,
) void {
    if (connection.*) |*active| active.deinit(io);
    if (!read_pending and !send_pending) connection.* = null;
    attached_pane_id.* = 0;
    exit_sent.* = false;
}

fn attachedPane(pane: ?*Pane, attached_id: u64, message_id: u64) !*Pane {
    const active = pane orelse return error.PaneNotFound;
    if (attached_id == 0 or message_id != attached_id or active.id != attached_id)
        return error.PaneNotFound;
    return active;
}

fn sendClient(
    io: Io,
    connection: *core.transport.SocketChannel,
    payload: []const u8,
) anyerror!void {
    try connection.send(io, payload);
}

fn writePaneInput(io: Io, master: File, bytes: []const u8) anyerror!void {
    try master.writeStreamingAll(io, bytes);
}

fn waitForStop(io: Io, stop: *Io.Queue(u8)) anyerror!void {
    _ = try stop.getOne(io);
}

fn acceptClient(io: Io, listener: *transport.local.LocalListener) anyerror!core.transport.SocketChannel {
    var connection = try listener.accept(io);
    errdefer connection.deinit(io);
    const response = try transport.handshake.perform(io, &connection);
    return switch (response) {
        .accepted => connection,
        .rejected => error.IncompatibleProtocol,
    };
}

fn receiveClient(
    io: Io,
    connection: *core.transport.SocketChannel,
    buffer: []u8,
) anyerror![]u8 {
    return connection.receive(io, buffer);
}

fn readPane(io: Io, master: File) anyerror!Output {
    var output: Output = .{};
    output.len = @intCast(try master.readStreaming(io, &.{&output.bytes}));
    return output;
}

fn waitPane(pane: *Pane) anyerror!pty.Exit {
    return pane.session.wait();
}

test "changed cells remain distinguishable for patch generation" {
    const cells = [_]core.ui.Cell{ .{}, .{}, .{} };
    var changed = cells;
    changed[0].bytes[0] = 'x';
    changed[2].bytes[0] = 'y';
    try std.testing.expect(!changed[0].eqlPublic(&cells[0]));
    try std.testing.expect(changed[1].eqlPublic(&cells[1]));
    try std.testing.expect(!changed[2].eqlPublic(&cells[2]));
}
