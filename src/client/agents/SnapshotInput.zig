const AgentInput = @import("AgentInput.zig");
const SnapshotInput = @This();

revision: u64,
agents: []const AgentInput,
