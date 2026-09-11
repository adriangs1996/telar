const TextDraw = @This();
const Surface = @import("Surface.zig");
const Point = @import("RasterizerPoint.zig");
const Color = @import("Color.zig");
surface: Surface,
origin: Point,
text: []const u8,
color: Color,
max_width: u32,
