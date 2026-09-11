const AgentSnapshotView = @This();
const AgentSnapshotIterator = @import("AgentSnapshotIterator.zig");
revision: u64,
entry_count: u16,
encoded_entries: []const u8,

pub fn entries(snapshot: AgentSnapshotView) AgentSnapshotIterator {
    return .{
        .decoder = .init(snapshot.encoded_entries),
        .remaining = snapshot.entry_count,
    };
}
