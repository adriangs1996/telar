const Shape = @import("Shape.zig");
const Input = @This();

pixels: []u8,
shape: Shape,
color: [3]u8,
stride: ?u32 = null,
