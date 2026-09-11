const WorkspaceIdType = @import("telar-core").WorkspaceId;
const WorkspaceRecoveryEffects = @This();

context: *anyopaque,
forget: *const fn (*anyopaque, WorkspaceIdType) void,
retry: *const fn (*anyopaque, WorkspaceIdType) anyerror!void,
