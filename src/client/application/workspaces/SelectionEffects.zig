const WorkspaceIdType = @import("telar-core").WorkspaceId;
const SelectionEffects = @This();

context: *anyopaque,
request: *const fn (*anyopaque, WorkspaceIdType) anyerror!void,
