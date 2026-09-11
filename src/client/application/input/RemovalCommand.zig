const PaneIdType = @import("telar-core").PaneId;
const MarkerRemovalType = @import("../../attachments/MarkerRemoval.zig");
const RemovalCommand = @This();

pane_id: PaneIdType,
marker: MarkerRemovalType,
