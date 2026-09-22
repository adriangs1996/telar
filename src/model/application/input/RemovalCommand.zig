const core = @import("telar-core");
const MarkerRemovalType = @import("../../attachments/MarkerRemoval.zig");
const RemovalCommand = @This();

pane_id: core.PaneId,
marker: MarkerRemovalType,
