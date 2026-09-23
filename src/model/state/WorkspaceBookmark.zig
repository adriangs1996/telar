const core = @import("telar-core");
const WorkspaceLayout = @import("../workspace/WorkspaceLayout.zig");
const WorkspaceBookmark = @This();

location: core.TabLocation,
pane_id: core.PaneId,
tab_layout: WorkspaceLayout,
