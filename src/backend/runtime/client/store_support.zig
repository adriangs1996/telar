//! Fixed-capacity ownership and generation-safe lookup of client sessions.

const core = @import("telar-core");
const Pane = @import("../../pane/Pane.zig");

pub const max_clients = core.ClientList.capacity;
pub const clients_limit = core.Limit.declare("clients.max_clients", "clients", max_clients);
/// Connections that may negotiate at once, refusals included. Hooks of
/// several agents connect together; a connection that arrives with every
/// slot taken is closed without an answer.
pub const max_pending_handshakes = 16;
pub const handshakes_limit = core.Limit.declare("clients.max_pending_handshakes", "handshakes", max_pending_handshakes);
/// The bits of `Pane.observers`, one per client slot.
pub const Observers = Pane.Observers;
/// A handshake still unfinished this long is interrupted at the next
/// maintenance tick, once a second, so a client that never finishes holds a
/// slot three seconds at most.
pub const handshake_deadline_ms: i64 = 2_000;
