const core = @import("telar-core");
const WriteInput = @This();

area: core.Rect,
x: *u16,
text: []const u8,
style: core.Style,
