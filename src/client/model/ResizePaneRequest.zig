const layout_support = @import("../workspace/layout_support.zig");
const RectType = @import("telar-core").Rect;
const ResizePaneRequest = @This();

direction: layout_support.Direction,
area: RectType,
