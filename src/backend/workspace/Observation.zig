const core = @import("telar-core");
const Observation = @This();

workspace: core.WorkspaceId,
branch: []const u8,
dirty: bool,
checked_at_ms: i64,
