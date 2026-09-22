const core = @import("telar-core");
const layout_support = @import("layout_support.zig");
const SplitTarget = @This();

pane_id: core.PaneId,
axis: layout_support.Axis,
