const WriteInput = @This();
const ui = @import("../ui/root.zig");
area: ui.Rect,
x: *u16,
text: []const u8,
style: ui.Style,
