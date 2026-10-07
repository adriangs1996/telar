//! A fixed header and bounded premultiplied pixels from the isolated helper.
const std = @import("std");
const Image = @import("Image.zig");

pub const header_bytes = 24;

/// Checks the complete header before allocating the declared image payload.
/// Example: `const length = try protocol.pixelBytes(&header);`
pub fn pixelBytes(header: []const u8) !usize {
    if (header.len != header_bytes or !std.mem.eql(u8, header[0..4], "TLRD") or std.mem.readInt(u32, header[20..24], .little) != 0) {
        return error.InvalidDiagram;
    }
    const width = std.mem.readInt(u32, header[4..8], .little);
    const height = std.mem.readInt(u32, header[8..12], .little);
    const logical_width: f32 = @bitCast(std.mem.readInt(u32, header[12..16], .little));
    const logical_height: f32 = @bitCast(std.mem.readInt(u32, header[16..20], .little));
    if (width == 0 or height == 0 or width > Image.max_side or height > Image.max_side or @as(u64, width) * height > Image.max_pixels or
        !std.math.isFinite(logical_width) or !std.math.isFinite(logical_height) or logical_width <= 0 or logical_height <= 0 or logical_width > 1_000_000 or logical_height > 1_000_000)
    {
        return error.DiagramLimit;
    }
    return @as(usize, width) * height * 4;
}

/// Adopts `bytes` on success, preserving the header allocation without a copy.
/// Example: `var image = try protocol.decode(bytes);`
pub fn decode(bytes: []u8) !Image {
    if (bytes.len < header_bytes) {
        return error.InvalidDiagram;
    }
    const length = try pixelBytes(bytes[0..header_bytes]);
    if (bytes.len != header_bytes + length) {
        return error.DiagramLimit;
    }
    const image: Image = .{
        .width = std.mem.readInt(u32, bytes[4..8], .little),
        .height = std.mem.readInt(u32, bytes[8..12], .little),
        .logical_width = @bitCast(std.mem.readInt(u32, bytes[12..16], .little)),
        .logical_height = @bitCast(std.mem.readInt(u32, bytes[16..20], .little)),
        .pixels = bytes[header_bytes..],
        .allocation = bytes,
    };
    if (!image.valid()) {
        return error.DiagramLimit;
    }
    return image;
}
