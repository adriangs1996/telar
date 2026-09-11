const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const PaneIdType = @import("telar-core").PaneId;
const Bookmarks = @This();

context: *anyopaque,
remembered_pane: *const fn (*anyopaque, WorkspaceLocationType) ?PaneIdType,
