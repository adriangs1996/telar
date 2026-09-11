const PaneIdType = @import("telar-core").PaneId;
const layout_support = @import("layout_support.zig");
const SplitRequest = @This();

existing_pane: PaneIdType,
new_pane: PaneIdType,
axis: layout_support.Axis,
