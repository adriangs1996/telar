const AgentSnapshotIterator = @This();
const wire = @import("../wire.zig");
const source_namespace = @import("agent.zig");
decoder: wire.Decoder,
remaining: u16,

pub fn next(iterator: *AgentSnapshotIterator) !?source_namespace.AgentSnapshotEntry {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    return try source_namespace.decodeAgentSnapshotEntry(&iterator.decoder);
}
