const PixelBlend = @This();
const Color = @import("Color.zig");
point: struct { x: u32, y: u32 },
color: Color,
alpha: u8,
