const core = @import("telar-core");
const data = @import("../model.zig");

location: core.TabLocation,
pane_id: core.PaneId,
tab_layout: ?data.WorkspaceLayout = null,
