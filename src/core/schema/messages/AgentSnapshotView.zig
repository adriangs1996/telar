const AgentSnapshotIterator = @import("AgentSnapshotIterator.zig");
const AgentSnapshotView = @This();

revision: u64,
entry_count: u16,
encoded_entries: []const u8,

pub fn entries(self: AgentSnapshotView) AgentSnapshotIterator {
    return .{
        .decoder = .init(self.encoded_entries),
        .remaining = self.entry_count,
    };
}
