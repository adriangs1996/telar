const Image = @import("Image.zig");
const Transmission = @This();

image_id: u32,
image: Image,
pixels: []const u8,
