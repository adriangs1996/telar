const Image = @import("Image.zig");
const SharedTransmission = @This();

image_id: u32,
image: Image,
name: []const u8,
