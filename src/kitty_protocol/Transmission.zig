const ImageType = @import("Image.zig");
const Transmission = @This();

image_id: u32,
image: ImageType,
pixels: []const u8,
