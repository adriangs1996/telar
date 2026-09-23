const Decoder = @import("../Decoder.zig");
const AgentSnapshotEntry = @import("../AgentSnapshotEntry.zig");
const agent = @import("agent.zig");
const AgentSnapshotIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(iterator: *AgentSnapshotIterator) !?AgentSnapshotEntry {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    return try agent.decodeAgentSnapshotEntry(&iterator.decoder);
}
