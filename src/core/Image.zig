const ImageKey = @import("ImageKey.zig");
const graphics = @import("graphics.zig");
const std = @import("std");
const Image = @This();

key: ImageKey,
format: graphics.Format,
width: u32,
height: u32,
byte_len: u64,

pub fn validate(image: Image, limit: usize) !usize {
    if (image.key.image_id == 0 or image.key.generation == 0) {
        return error.InvalidImageIdentity;
    }
    if (image.width == 0 or image.height == 0) {
        return error.InvalidImageDimensions;
    }
    const pixels = std.math.mul(usize, image.width, image.height) catch
        return error.ImageSizeOverflow;
    const expected = std.math.mul(usize, pixels, image.format.bytesPerPixel()) catch
        return error.ImageSizeOverflow;
    if (image.byte_len != expected) {
        return error.InvalidImageLength;
    }
    if (expected > limit) {
        return error.ImageQuotaExceeded;
    }
    return expected;
}
