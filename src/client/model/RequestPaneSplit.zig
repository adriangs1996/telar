const layout_support = @import("../workspace/layout_support.zig");
const RectType = @import("telar-core").Rect;
const RequestPaneSplit = @This();

axis: layout_support.Axis,
area: RectType,
