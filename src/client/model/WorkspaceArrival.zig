const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const TerminalSizeType = @import("telar-core").TerminalSize;
const LayoutType = @import("../workspace/WorkspaceLayout.zig");
const WorkspaceArrival = @This();

pane_id: PaneIdType,
location: TabLocationType,
size: TerminalSizeType,
saved_layout: ?LayoutType = null,
