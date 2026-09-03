//! One disposable runtime-side client connection and its delivery state.

const std = @import("std");
const core = @import("telar-core");
const history = @import("../../history/root.zig");
const attachment_mod = @import("../attachment/root.zig");
const delivery_mod = @import("../delivery/root.zig");

const Io = std.Io;

pub const Key = history.model.ClientKey;
pub const Role = enum { undecided, ui, control };

pub const PendingPaneFocus = struct {
    request_id: core.schema.RequestId,
    pane_id: core.schema.PaneId,
    pane_generation: u64,
    target: Key,
};

pub const Session = struct {
    key: Key,
    connection: core.transport.SocketChannel,
    receive_buffer: []u8,
    read_buffer: []u8,
    attachments: attachment_mod.AttachmentStore = .{},
    delivery: delivery_mod.Delivery,
    role: Role = .undecided,
    read_pending: bool = false,
    send_pending: bool = false,
    closing: bool = false,
    last_input_pane: core.schema.PaneId = .invalid,
    last_input_sequence: u64 = 0,
    pending_pane_focus: ?PendingPaneFocus = null,

    /// Allocates the bounded receive and delivery buffers for one connection.
    /// The returned session owns neither `gpa` nor `connection` until the
    /// caller retains the successful result.
    ///
    /// ```zig
    /// const session = try Session.create(gpa, key, connection);
    /// ```
    pub fn create(gpa: std.mem.Allocator, key: Key, connection: core.transport.SocketChannel) !*Session {
        const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
        errdefer gpa.free(receive_buffer);
        const read_buffer = try gpa.alloc(u8, core.transport.read_buffer_size);
        errdefer gpa.free(read_buffer);

        var delivery = try delivery_mod.Delivery.init(gpa);
        errdefer delivery.deinit(gpa);

        const session = try gpa.create(Session);
        session.* = .{
            .key = key,
            .connection = connection,
            .receive_buffer = receive_buffer,
            .read_buffer = read_buffer,
            .delivery = delivery,
        };
        session.connection.bindReadBuffer(read_buffer);
        return session;
    }

    /// Reports whether the connection can still receive or send application work.
    ///
    /// ```zig
    /// if (session.active()) try scheduleRead(session);
    /// ```
    pub fn active(session: *const Session) bool {
        return !session.closing and session.connection.isActive();
    }

    /// Releases connection, attachment and buffer ownership after all socket
    /// operations have completed.
    ///
    /// ```zig
    /// session.deinit(io, gpa);
    /// gpa.destroy(session);
    /// ```
    pub fn deinit(session: *Session, io: Io, gpa: std.mem.Allocator) void {
        std.debug.assert(!session.read_pending and !session.send_pending);
        session.connection.deinit(io);
        session.attachments.deinit();
        session.delivery.deinit(gpa);
        gpa.free(session.receive_buffer);
        gpa.free(session.read_buffer);
    }
};

pub const Write = struct {
    io: Io,
    key: Key,
    connection: *core.transport.SocketChannel,
    payload: []const u8,
};

pub const Read = struct {
    io: Io,
    key: Key,
    connection: *core.transport.SocketChannel,
    buffer: []u8,
};

test "Session keeps its bounded buffers outside client store storage" {
    const session = try Session.create(
        std.testing.allocator,
        .{ .id = 1, .generation = 1 },
        .{ .stream = undefined },
    );
    defer {
        session.delivery.deinit(std.testing.allocator);
        std.testing.allocator.free(session.receive_buffer);
        std.testing.allocator.free(session.read_buffer);
        std.testing.allocator.destroy(session);
    }

    try std.testing.expectEqual(@as(u64, 1), session.key.id);
    try std.testing.expectEqual(core.transport.max_frame_size, session.receive_buffer.len);
    try std.testing.expectEqual(core.transport.max_frame_size, session.delivery.send_buffer.len);
}
