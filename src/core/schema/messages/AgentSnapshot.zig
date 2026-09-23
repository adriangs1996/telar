const AgentSnapshotEntry = @import("../AgentSnapshotEntry.zig");
const AgentSnapshot = @This();

revision: u64,
entries: []const AgentSnapshotEntry,
