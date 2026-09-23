const core = @import("telar-core");
const ClientKey = @import("../../history/ClientKey.zig");
const AttachmentStore = @import("../attachment/AttachmentStore.zig");
const Delivery = @import("../delivery/Delivery.zig");
const session_support = @import("session_support.zig");
const PendingPaneFocus = @import("PendingPaneFocus.zig");
const PaneKey = @import("../../pane/PaneKey.zig");
const Cursor = @import("../../pane/Cursor.zig");
const std = @import("std");
const PendingClientCommand = @import("PendingClientCommand.zig");
const Session = @This();

key: ClientKey,
connection: core.SocketChannel,
receive_buffer: []u8,
read_buffer: []u8,
attachments: AttachmentStore = .{},
delivery: Delivery,
role: session_support.Role = .undecided,
read_pending: bool = false,
send_pending: bool = false,
closing: bool = false,
last_input_pane: core.PaneId = .invalid,
last_input_sequence: u64 = 0,
pending_client_command: ?PendingClientCommand = null,
pending_pane_focus: ?PendingPaneFocus = null,
terminal_colors: core.TerminalColors = .{},
pending_search: ?PendingSearch = null,
search_scheduled: bool = false,
cell_deadline_ns: ?u64 = null,

/// Example: `if (session.setTerminalColors(colors)) { updateOwnedPanes(); }`.
pub fn setTerminalColors(self: *Session, colors: core.TerminalColors) bool {
    if (std.meta.eql(self.terminal_colors, colors)) {
        return false;
    }

    self.terminal_colors = colors;
    return true;
}

/// Reserves one correlated focus exchange before its command is delivered.
/// Example: `try session.reserveFocus(pending);`.
pub fn reserveFocus(self: *Session, pending: PendingPaneFocus) !void {
    if (self.pending_pane_focus != null) {
        return error.FocusAlreadyPending;
    }

    self.pending_pane_focus = pending;
}

/// Retires a completed or undeliverable focus exchange.
/// Example: `session.releaseFocus();`.
pub fn releaseFocus(self: *Session) void {
    self.pending_pane_focus = null;
}

/// Checks all correlation fields without consuming an unrelated completion.
/// Example: `if (!session.acceptsFocusCompletion(sender, reply)) return;`.
pub fn acceptsFocusCompletion(self: *const Session, sender: ClientKey, reply: core.CompletePaneFocus) bool {
    const pending = self.pending_pane_focus orelse return false;

    return std.meta.eql(pending.target, sender) and pending.request_id == reply.request_id and
        pending.pane_id == reply.pane_id and pending.pane_generation == reply.pane_generation;
}

/// Allocates the bounded receive and delivery buffers for one connection.
/// The returned session owns neither `gpa` nor `connection` until the
/// caller retains the successful result.
///
/// ```zig
/// const session = try Session.create(gpa, key, connection);
/// ```
pub fn create(gpa: std.mem.Allocator, key: ClientKey, connection: core.SocketChannel) !*Session {
    const receive_buffer = try gpa.alloc(u8, core.max_frame_size);
    errdefer gpa.free(receive_buffer);
    const read_buffer = try gpa.alloc(u8, core.read_buffer_size);
    errdefer gpa.free(read_buffer);

    var delivery = try Delivery.init(gpa);
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
pub fn active(self: *const Session) bool {
    return !self.closing and self.connection.isActive();
}

/// Releases connection, attachment and buffer ownership after all socket
/// operations have completed.
///
/// ```zig
/// session.deinit(io, gpa);
/// gpa.destroy(session);
/// ```
pub fn deinit(self: *Session, io: std.Io, gpa: std.mem.Allocator) void {
    std.debug.assert(!self.read_pending and !self.send_pending);
    self.connection.deinit(io);
    self.attachments.deinit();
    self.delivery.deinit(gpa);
    gpa.free(self.receive_buffer);
    gpa.free(self.read_buffer);
}

const PendingSearch = struct {
    request_id: core.RequestId,
    pane: PaneKey,
    cursor: Cursor,
    deadline_ns: i128,
};
