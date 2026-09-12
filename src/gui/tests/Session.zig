//! Native adapter fixture using the production controllers and owned outbox.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const GuiClient = @import("../GuiClient.zig");
const RuntimeDriver = @import("../RuntimeDriver.zig");
const Renderer = @import("../render/TerminalRenderer.zig");
const Session = @This();

connection: core.SocketChannel,
peer: core.SocketChannel,
driver: RuntimeDriver,
gui: *GuiClient,
renderer: Renderer,
pending: ?[]const u8 = null,
acknowledgements: [128]core.FrameAck = undefined,
ack_count: usize = 0,
input: [4096]u8 = undefined,
input_len: usize = 0,
resize_count: usize = 0,

pub const pane_id: core.PaneId = @enumFromInt(10);
pub const location: core.TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) };

pub fn init() !*Session {
    const session = try std.testing.allocator.create(Session);
    errdefer std.testing.allocator.destroy(session);
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketPairFailed;
    }

    session.* = .{
        .connection = .init(.{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .loopback(0) } } }),
        .peer = .init(.{ .socket = .{ .handle = fds[1], .address = .{ .ip4 = .loopback(0) } } }),
        .driver = try RuntimeDriver.init(std.testing.io),
        .gui = undefined,
        .renderer = .init(std.testing.allocator),
    };
    errdefer session.connection.deinit(std.testing.io);
    errdefer session.peer.deinit(std.testing.io);
    errdefer session.driver.deinit();
    errdefer session.renderer.deinit();
    const size = try session.renderer.measure(.{ .width = 180, .height = 72, .scale = 1 });
    session.gui = try GuiClient.init(.{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .connection = &session.connection,
        .host_size = size,
        .window_width_px = @as(u32, size.cols) * size.cell_width_px,
        .window_height_px = @as(u32, size.rows) * size.cell_height_px,
        .options = .{ .arguments = &.{"/bin/sh"}, .cwd = "/", .endpoint = "" },
    }, &session.driver);
    session.gui.app.transport_driver = .{ .context = session, .start_read_fn = noRead, .start_send_fn = captureSend };
    return session;
}

pub fn deinit(session: *Session) void {
    session.driver.deinit();
    session.gui.deinit();
    session.renderer.deinit();
    session.connection.deinit(std.testing.io);
    session.peer.deinit(std.testing.io);
    std.testing.allocator.destroy(session);
}

fn noRead(_: *anyopaque, _: *client.RuntimeTransportState) !void {}

fn captureSend(context: *anyopaque, _: *client.RuntimeTransportState, bytes: []const u8) !void {
    const session: *Session = @ptrCast(@alignCast(context));
    std.debug.assert(session.pending == null);
    session.pending = bytes;
}

pub fn settle(session: *Session) !void {
    var count: usize = 0;
    while (session.pending) |bytes| {
        if (count == 2048) {
            return error.UnboundedDelivery;
        }

        count += 1;
        switch (try core.decodeClient(bytes)) {
            .frame_ack => |ack| {
                if (session.ack_count == session.acknowledgements.len) {
                    return error.AckCapacityExceeded;
                }

                session.acknowledgements[session.ack_count] = ack;
                session.ack_count += 1;
            },
            .pane_input => |value| {
                if (value.bytes.len > session.input.len - session.input_len) {
                    return error.InputCapacityExceeded;
                }

                @memcpy(session.input[session.input_len..][0..value.bytes.len], value.bytes);
                session.input_len += value.bytes.len;
            },
            .pane_resize => session.resize_count += 1,
            else => {},
        }

        session.pending = null;
        try client.runtime_io.handleSent(&session.gui.app, {});
    }
}

pub fn bootstrap(session: *Session) !void {
    const app = &session.gui.app;
    _ = try client.request_lifecycle.registerInitial(app);
    var buffer: [128]u8 = undefined;
    const opened = try core.encodePaneOpened(&buffer, .{ .request_id = client.initial_request_id, .pane_id = pane_id, .location = location, .created = true });
    _ = try client.server_messages.handleServerMessage(app, try core.decodeServer(opened));
    app.startup.phase = .active;
    try session.settle();
}

pub fn receiveFrame(session: *Session, frame_id: u64) !void {
    const pane = session.gui.app.model.workspace.findPane(pane_id).?;
    const count = pane.buffer.cells.len;
    var cells: [256]core.Cell = @splat(.{});
    if (count > cells.len) {
        return error.TestScreenTooLarge;
    }

    cells[0].bytes[0] = if (frame_id == 1) '$' else 'A' + @as(u8, @intCast(frame_id % 26));
    var wire: [8192]u8 = undefined;
    const encoded = try core.encodePaneFrame(&wire, .{
        .pane_id = pane_id,
        .frame_id = frame_id,
        .base_frame_id = frame_id - 1,
        .cols = pane.buffer.w,
        .rows = pane.buffer.h,
        .cursor = .{ .visible = true, .x = 1, .y = 0 },
        .scroll = .{ .total_rows = pane.buffer.h, .offset = 0 },
        .input_modes = .{ .bracketed_paste = true },
        .spans = &.{.{ .start = 0, .cells = if (frame_id == 1) cells[0..count] else cells[0..1] }},
    });
    _ = try client.server_messages.handleServerMessage(&session.gui.app, try core.decodeServer(encoded));
    @memset(&wire, 0xff);
}
