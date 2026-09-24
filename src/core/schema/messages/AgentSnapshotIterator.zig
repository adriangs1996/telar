const bytecodec = @import("bytecodec");
const Decoder = bytecodec.Decoder;
const AgentSnapshotEntry = @import("../AgentSnapshotEntry.zig");
const agent = @import("agent.zig");
const AgentSnapshotIterator = @This();

decoder: Decoder,
remaining: u16,

pub fn next(self: *AgentSnapshotIterator) !?AgentSnapshotEntry {
    if (self.remaining == 0) {
        return null;
    }
    self.remaining -= 1;
    return try agent.decodeAgentSnapshotEntry(&self.decoder);
}
