const data = @import("model");
const SnapshotInput = @This();

revision: u64,
agents: []const data.AgentInput,
