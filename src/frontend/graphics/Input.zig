const Input = @This();
const Shape = @import("Shape.zig");
pixels: []u8,
shape: Shape,
color: [3]u8,
stride: ?u32 = null,
