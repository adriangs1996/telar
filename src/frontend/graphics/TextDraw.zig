const Surface = @import("Surface.zig");
const RasterizerPoint = @import("RasterizerPoint.zig");
const Color = @import("Color.zig");
const TextDraw = @This();

surface: Surface,
origin: RasterizerPoint,
text: []const u8,
color: Color,
max_width: u32,
