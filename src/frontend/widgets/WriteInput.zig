const RectType = @import("telar-core").Rect;
const StyleType = @import("telar-core").Style;
const WriteInput = @This();

area: RectType,
x: *u16,
text: []const u8,
style: StyleType,
