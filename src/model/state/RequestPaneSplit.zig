const core = @import("telar-core");
const layout_support = @import("../workspace/layout_support.zig");
const RequestPaneSplit = @This();

axis: layout_support.Axis,
area: core.Rect,
target_pane: ?core.PaneId = null,
arguments: []const []const u8 = &.{},
