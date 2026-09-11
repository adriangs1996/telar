const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const Effects = @This();

context: *anyopaque,
forget_workspace: *const fn (*anyopaque, WorkspaceLocationType) void,
request_snapshot: *const fn (*anyopaque, WorkspaceLocationType) anyerror!void,
request_handoff: *const fn (*anyopaque, WorkspaceIdType) anyerror!void,
