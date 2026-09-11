const ImageType = @import("telar-core").Image;
const Transmission = @This();

external_id: u32,
image: ImageType,
pixels: []const u8,
