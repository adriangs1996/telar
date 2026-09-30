const localsocket = @import("localsocket");
const core = @import("telar-core");
const ClientKey = @import("../../history/ClientKey.zig");
const Delivery = @import("../delivery/Delivery.zig");
const session_support = @import("session_support.zig");
const PendingPaneFocus = @import("PendingPaneFocus.zig");
const PaneKey = @import("../../pane/PaneKey.zig");
const Cursor = @import("../../pane/text_search.zig").Search;
const std = @import("std");
const PendingClientCommand = @import("PendingClientCommand.zig");
const Session = @This();

/// Parent processes kept from a descent check: an agent, its launcher and a
/// few shells between the pane's root process and the hook fit well within.
pub const max_hook_lineage = 32;

key: ClientKey,
connection: localsocket.SocketChannel,
receive_buffer: []u8,
read_buffer: []u8,
/// The client's position in `RuntimeModel.clients`: its row in
/// `RuntimeModel.attachments` and its bit in `Pane.observers`.
slot: usize = 0,
/// The workspace the client views, kept after its last attachment until
/// lifecycle events that depend on it are published.
workspace: ?core.WorkspaceLocation = null,
/// Graphics transport for existing and future attachments.
shared_graphics: bool = false,
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
/// The pane generation the process at the other end of this connection
/// descends from, as the runtime confirmed. Only then may the connection
/// report for that pane in the name of an agent.
hook_pane: ?PaneKey = null,
/// A worker is walking the peer process's parents for `verify_pane_descent`.
descent_pending: bool = false,
/// The confirmed peer's parent processes, nearest first, as the descent
/// check walked them.
hook_lineage: [max_hook_lineage]u32 = undefined,
hook_lineage_len: u8 = 0,
/// A hook report held while the pane's process is identified again. The
/// connection reads nothing more until it is answered, so the report's
/// bytes stay in the receive buffer.
parked: ?core.ClientMessage = null,
/// The pane the parked report names and the count of its completed
/// rechecks that answers it: one started after the report arrived.
parked_pane: PaneKey = undefined,
parked_recheck: u32 = 0,
/// Monotonic arrival, for the deadline.
parked_at_ms: i64 = 0,
/// When the report arrived, which it keeps when answered later.
parked_real_ms: i64 = 0,
parked_awake_ns: i64 = 0,
/// Arrival order among parked reports.
parked_sequence: u64 = 0,
/// The parked report is being dispatched again; another agent then is the
/// pane's final answer.
answering_parked: bool = false,
/// It is dispatched because its recheck ran, not because it waited too
/// long, so a refusal is remembered.
parked_rechecked: bool = false,
cell_deadline_ns: ?u64 = null,

/// Example: `if (session.setTerminalColors(colors)) { updateOwnedPanes(); }`.
pub fn setTerminalColors(self: *Session, colors: core.TerminalColors) bool {
    if (std.meta.eql(self.terminal_colors, colors)) {
        return false;
    }

    self.terminal_colors = colors;
    return true;
}

/// Example: `if (!session.observes(workspace)) { continue; }`.
pub fn observes(self: *const Session, workspace: core.WorkspaceLocation) bool {
    return self.workspace != null and std.meta.eql(self.workspace.?, workspace);
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
pub fn create(gpa: std.mem.Allocator, key: ClientKey, connection: localsocket.SocketChannel) !*Session {
    const receive_buffer = try gpa.alloc(u8, localsocket.transport.max_frame_size);
    errdefer gpa.free(receive_buffer);
    const read_buffer = try gpa.alloc(u8, localsocket.transport.read_buffer_size);
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

/// Releases connection and buffer ownership after all socket operations
/// have completed and the client's attachments are gone.
///
/// ```zig
/// session.deinit(io, gpa);
/// gpa.destroy(session);
/// ```
pub fn deinit(self: *Session, io: std.Io, gpa: std.mem.Allocator) void {
    std.debug.assert(!self.read_pending and !self.send_pending);
    self.connection.deinit(io);
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
