const Color = @import("Color.zig");
const PixelBlend = @This();

point: struct { x: u32, y: u32 },
color: Color,
alpha: u8,
