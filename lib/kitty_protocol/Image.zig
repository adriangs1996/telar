const image_support = @import("image_support.zig");
const Image = @This();

format: image_support.Format,
width: u32,
height: u32,
