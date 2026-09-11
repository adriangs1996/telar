const ImageType = @import("Image.zig");
const SharedTransmission = @This();

image_id: u32,
image: ImageType,
name: []const u8,
