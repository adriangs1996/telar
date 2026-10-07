//! Straight to premultiplied alpha, rounding to nearest, the form GPU
//! blending and the platform decoders use.
const std = @import("std");

const channel_max = 255;
const half = channel_max / 2;

/// One straight RGBA pixel with its color scaled by its alpha.
///
/// ```zig
/// out.* = premultiply.pixel(rgba);
/// ```
pub fn pixel(rgba: [4]u8) [4]u8 {
    var out = rgba;
    inline for (0..3) |channel| {
        out[channel] = @intCast((@as(u32, rgba[channel]) * rgba[3] + half) / channel_max);
    }

    return out;
}

/// Premultiplies packed RGBA in place.
///
/// ```zig
/// premultiply.inPlace(decoded.pixels);
/// ```
pub fn inPlace(pixels: []u8) void {
    std.debug.assert(pixels.len % 4 == 0);

    var index: usize = 0;
    while (index < pixels.len) : (index += 4) {
        pixels[index..][0..4].* = pixel(pixels[index..][0..4].*);
    }
}
