//! One clipped label written at a column of a single-row area.
const RectType = @import("telar-core").Rect;
const StyleType = @import("telar-core").Style;
const InlineLabel = @This();

area: RectType,
x: u16,
text: []const u8,
style: StyleType,
