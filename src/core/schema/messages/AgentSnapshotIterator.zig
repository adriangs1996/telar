const DecoderType = @import("../Decoder.zig");
const AgentSnapshotEntryType = @import("../AgentSnapshotEntry.zig");
const agent = @import("agent.zig");
const AgentSnapshotIterator = @This();

decoder: DecoderType,
remaining: u16,

pub fn next(iterator: *AgentSnapshotIterator) !?AgentSnapshotEntryType {
    if (iterator.remaining == 0) {
        return null;
    }
    iterator.remaining -= 1;
    return try agent.decodeAgentSnapshotEntry(&iterator.decoder);
}
