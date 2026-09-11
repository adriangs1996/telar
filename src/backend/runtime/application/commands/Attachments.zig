const PaneIdType = @import("telar-core").PaneId;
const PaneDetachedType = @import("../../attachment/PaneDetached.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const Attachments = @This();

context: *anyopaque,
detach: *const fn (*anyopaque, PaneIdType) ?PaneDetachedType,
leave_workspace: *const fn (*anyopaque, WorkspaceLocationType) bool,
