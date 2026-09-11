const AgentSnapshot = @This();
const source_namespace = @import("agent.zig");
revision: u64,
entries: []const source_namespace.AgentSnapshotEntry,
