const WorkspaceIdType = @import("telar-core").WorkspaceId;
const Observation = @This();

workspace: WorkspaceIdType,
branch: []const u8,
dirty: bool,
checked_at_ms: i64,
