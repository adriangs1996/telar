const KittyFramingCounter = @import("../history/KittyFramingCounter.zig");
const PreparedTransfersType = @import("PreparedTransfers.zig");
const QueueType = @import("Queue.zig");
const std = @import("std");
const State = @This();

kitty_framing: KittyFramingCounter = .{},
kitty_loading_chunks: usize = 0,
/// Generations the media actor froze for local clients, awaiting
/// adoption on the runtime thread.
prepared_transfers: PreparedTransfersType = .{},
transfer_preparation: QueueType = .{},
/// Attachments whose client takes shared-memory names. Written by the
/// runtime thread, read by the media actor to decide whether freezing a
/// generation right after decode can pay off.
shared_transport_clients: std.atomic.Value(u8) = .init(0),

/// Example: `state.noteSharedTransport(true);`.
pub fn noteSharedTransport(state: *State, shared: bool) void {
    if (shared) {
        _ = state.shared_transport_clients.fetchAdd(1, .release);
    } else {
        _ = state.shared_transport_clients.fetchSub(1, .release);
    }
}
