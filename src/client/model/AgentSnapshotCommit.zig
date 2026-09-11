const AgentSnapshotCommit = @This();
const AgentStatusChanges = @import("AgentStatusChanges.zig");
runtime_revision: u64,
count: usize,
status_changes: AgentStatusChanges,
agent_revision_before: u64,
agent_revision: u64,
