const core = @import("telar-core");
const layout_support = @import("layout_support.zig");
const SplitRequest = @This();

existing_pane: core.PaneId,
new_pane: core.PaneId,
axis: layout_support.Axis,
