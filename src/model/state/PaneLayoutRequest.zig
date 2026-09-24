const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const WorkspaceLayout = @import("../workspace/WorkspaceLayout.zig");
const PaneSet = @import("../workspace/PaneSet.zig");
location: core.TabLocation,
layout: WorkspaceLayout,
panes: PaneSet,
area: cellgrid.Rect,
