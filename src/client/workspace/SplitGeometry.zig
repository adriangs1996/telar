const RectType = @import("telar-core").Rect;
const layout_support = @import("layout_support.zig");
const SplitGeometry = @This();

area: RectType,
axis: layout_support.Axis,
ratio: u16,
gap: u16,
