const core = @import("telar-core");
const LayoutType = @import("../workspace/WorkspaceLayout.zig");
const WorkspaceArrival = @This();

pane_id: core.PaneId,
location: core.TabLocation,
size: core.TerminalSize,
saved_layout: ?LayoutType = null,
