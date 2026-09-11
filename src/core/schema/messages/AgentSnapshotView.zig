const AgentSnapshotIterator = @import("AgentSnapshotIterator.zig");
const AgentSnapshotView = @This();

revision: u64,
entry_count: u16,
encoded_entries: []const u8,

pub fn entries(snapshot: AgentSnapshotView) AgentSnapshotIterator {
    return .{
        .decoder = .init(snapshot.encoded_entries),
        .remaining = snapshot.entry_count,
    };
}
