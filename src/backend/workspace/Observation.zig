const Observation = @This();
const source_namespace = @import("git_observation.zig");
workspace: source_namespace.schema.WorkspaceId,
branch: []const u8,
dirty: bool,
checked_at_ms: i64,
