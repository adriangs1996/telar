const core = @import("telar-core");
const data = @import("model");
const Bookmark = @This();

location: core.TabLocation,
pane_id: core.PaneId,
tab_layout: ?data.WorkspaceLayout = null,
