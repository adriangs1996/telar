const core = @import("telar-core");
const WorkspaceLayout = @import("../workspace/WorkspaceLayout.zig");

pane_id: core.PaneId,
location: core.TabLocation,
size: core.TerminalSize,
saved_layout: ?WorkspaceLayout = null,
