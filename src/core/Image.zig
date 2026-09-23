const ImageKey = @import("ImageKey.zig");
const graphics = @import("graphics.zig");
const std = @import("std");
const Image = @This();

key: ImageKey,
format: graphics.Format,
width: u32,
height: u32,
byte_len: u64,

pub fn validate(self: Image, limit: usize) !usize {
    if (self.key.image_id == 0 or self.key.generation == 0) {
        return error.InvalidImageIdentity;
    }
    if (self.width == 0 or self.height == 0) {
        return error.InvalidImageDimensions;
    }
    const pixels = std.math.mul(usize, self.width, self.height) catch
        return error.ImageSizeOverflow;
    const expected = std.math.mul(usize, pixels, self.format.bytesPerPixel()) catch
        return error.ImageSizeOverflow;
    if (self.byte_len != expected) {
        return error.InvalidImageLength;
    }
    if (expected > limit) {
        return error.ImageQuotaExceeded;
    }
    return expected;
}
