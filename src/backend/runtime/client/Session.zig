const ClientKey = @import("../../history/ClientKey.zig");
const SocketChannelType = @import("telar-core").SocketChannel;
const AttachmentStoreType = @import("../attachment/AttachmentStore.zig");
const DeliveryType = @import("../delivery/Delivery.zig");
const session_support = @import("session_support.zig");
const PaneIdType = @import("telar-core").PaneId;
const PendingPaneFocus = @import("PendingPaneFocus.zig");
const TerminalColorsType = @import("telar-core").TerminalColors;
const PendingType = @import("../application/Pending.zig");
const std = @import("std");
const CompletePaneFocusType = @import("telar-core").CompletePaneFocus;
const max_frame_size_module = @import("telar-core").max_frame_size;
const read_buffer_size_module = @import("telar-core").read_buffer_size;
const Session = @This();

key: ClientKey,
connection: SocketChannelType,
receive_buffer: []u8,
read_buffer: []u8,
attachments: AttachmentStoreType = .{},
delivery: DeliveryType,
role: session_support.Role = .undecided,
read_pending: bool = false,
send_pending: bool = false,
closing: bool = false,
last_input_pane: PaneIdType = .invalid,
last_input_sequence: u64 = 0,
pending_pane_focus: ?PendingPaneFocus = null,
terminal_colors: TerminalColorsType = .{},
pending_search: ?PendingType = null,
search_scheduled: bool = false,

/// Example: `if (session.setTerminalColors(colors)) { updateOwnedPanes(); }`.
pub fn setTerminalColors(session: *Session, colors: TerminalColorsType) bool {
    if (std.meta.eql(session.terminal_colors, colors)) {
        return false;
    }

    session.terminal_colors = colors;
    return true;
}

/// Reserves one correlated focus exchange before its command is delivered.
/// Example: `try session.reserveFocus(pending);`.
pub fn reserveFocus(session: *Session, pending: PendingPaneFocus) !void {
    if (session.pending_pane_focus != null) {
        return error.FocusAlreadyPending;
    }

    session.pending_pane_focus = pending;
}

/// Retires a completed or undeliverable focus exchange.
/// Example: `session.releaseFocus();`.
pub fn releaseFocus(session: *Session) void {
    session.pending_pane_focus = null;
}

/// Checks all correlation fields without consuming an unrelated completion.
/// Example: `if (!session.acceptsFocusCompletion(sender, reply)) return;`.
pub fn acceptsFocusCompletion(session: *const Session, sender: ClientKey, reply: CompletePaneFocusType) bool {
    const pending = session.pending_pane_focus orelse return false;

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
pub fn create(gpa: std.mem.Allocator, key: ClientKey, connection: SocketChannelType) !*Session {
    const receive_buffer = try gpa.alloc(u8, max_frame_size_module);
    errdefer gpa.free(receive_buffer);
    const read_buffer = try gpa.alloc(u8, read_buffer_size_module);
    errdefer gpa.free(read_buffer);

    var delivery = try DeliveryType.init(gpa);
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
pub fn deinit(session: *Session, io: std.Io, gpa: std.mem.Allocator) void {
    std.debug.assert(!session.read_pending and !session.send_pending);
    session.connection.deinit(io);
    session.attachments.deinit();
    session.delivery.deinit(gpa);
    gpa.free(session.receive_buffer);
    gpa.free(session.read_buffer);
}
