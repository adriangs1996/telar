const data = @import("../model.zig");
const SnapshotInput = @This();

revision: u64,
agents: []const data.AgentInput,
