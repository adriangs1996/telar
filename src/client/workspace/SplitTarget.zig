const PaneIdType = @import("telar-core").PaneId;
const layout_support = @import("layout_support.zig");
const SplitTarget = @This();

pane_id: PaneIdType,
axis: layout_support.Axis,
