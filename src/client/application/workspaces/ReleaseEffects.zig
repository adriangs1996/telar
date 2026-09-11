const WorkspaceBookmarkType = @import("../../model/WorkspaceBookmark.zig");
const PaneIdType = @import("telar-core").PaneId;
const ReleaseEffects = @This();

context: *anyopaque,
remember_bookmark: *const fn (*anyopaque, WorkspaceBookmarkType) void,
clear_pane_graphics: *const fn (*anyopaque, PaneIdType) void,
