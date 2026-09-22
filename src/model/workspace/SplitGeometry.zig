const core = @import("telar-core");
const layout_support = @import("layout_support.zig");
const SplitGeometry = @This();

area: core.Rect,
axis: layout_support.Axis,
ratio: u16,
gap: u16,
