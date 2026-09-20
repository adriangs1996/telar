const layout_support = @import("../workspace/layout_support.zig");
const RectType = @import("telar-core").Rect;
const PaneId = @import("telar-core").PaneId;
const RequestPaneSplit = @This();

axis: layout_support.Axis,
area: RectType,
target_pane: ?PaneId = null,
arguments: []const []const u8 = &.{},
