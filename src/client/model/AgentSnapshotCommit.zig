const AgentStatusChanges = @import("AgentStatusChanges.zig");
const AgentSnapshotCommit = @This();

runtime_revision: u64,
count: usize,
status_changes: AgentStatusChanges,
agent_revision_before: u64,
agent_revision: u64,
