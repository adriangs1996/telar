//! Identity of the agent snapshot a sidebar last ordered: its revision, the
//! replica it came from and its length. Equal marks mean the same list.
const std = @import("std");
const AgentSnapshot = @import("telar-client").AgentSnapshot;
const SnapshotMark = @This();

revision: u64 = 0,
source: usize = 0,
len: usize = 0,

/// Example: `if (!mark.eql(SnapshotMark.of(projection.agents))) resort();`
pub fn of(snapshot: *const AgentSnapshot) SnapshotMark {
    return .{ .revision = snapshot.revision, .source = @intFromPtr(snapshot), .len = snapshot.slice().len };
}

/// Example: `if (mark.eql(SnapshotMark.of(snapshot))) return;`
pub fn eql(mark: SnapshotMark, other: SnapshotMark) bool {
    return std.meta.eql(mark, other);
}
