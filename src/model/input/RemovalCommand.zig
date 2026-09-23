const core = @import("telar-core");
const MarkerRemoval = @import("../attachments/MarkerRemoval.zig");
const RemovalCommand = @This();

pane_id: core.PaneId,
marker: MarkerRemoval,
