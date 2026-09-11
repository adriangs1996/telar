const WorkspaceRecoveryEffects = @This();
const source_namespace = @import("workspace_handoff.zig");
context: *anyopaque,
forget: *const fn (*anyopaque, source_namespace.schema.WorkspaceId) void,
retry: *const fn (*anyopaque, source_namespace.schema.WorkspaceId) anyerror!void,
