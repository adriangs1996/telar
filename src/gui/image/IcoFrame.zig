//! One validated ICO representation, borrowing its bytes until decoding.
//! Dimensions come from the directory and must match the payload. Only PNG
//! and uncompressed 32-bit BITMAPINFOHEADER images are supported.
const std = @import("std");
const png = @import("png.zig");
const DecodedImage = @import("DecodedImage.zig");
const IcoFrame = @This();

width: u32,
height: u32,
bytes: []const u8,
format: enum { png, dib },

/// Validates a directory entry's dimensions and bitmap layout before allocation.
/// Example: `const frame = try IcoFrame.init(entry, payload);`
pub fn init(entry: *const [16]u8, bytes: []const u8) !IcoFrame {
    const width: u32 = if (entry[0] == 0) 256 else entry[0];
    const height: u32 = if (entry[1] == 0) 256 else entry[1];
    if (entry[3] != 0) {
        return error.InvalidIcoData;
    }

    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) {
        return .{ .width = width, .height = height, .bytes = bytes, .format = .png };
    }

    if (bytes.len < 40) {
        return error.InvalidIcoData;
    }

    if (std.mem.readInt(u32, bytes[0..4], .little) != 40 or
        std.mem.readInt(u16, bytes[14..16], .little) != 32 or
        std.mem.readInt(u32, bytes[16..20], .little) != 0 or
        std.mem.readInt(u32, bytes[32..36], .little) != 0)
    {
        return error.UnsupportedIco;
    }

    if (std.mem.readInt(u32, bytes[4..8], .little) != width or
        std.mem.readInt(u32, bytes[8..12], .little) != height * 2 or
        std.mem.readInt(u16, bytes[12..14], .little) != 1)
    {
        return error.InvalidIcoData;
    }

    const mask_stride = ((width + 31) / 32) * 4;
    if (bytes.len < 40 + (width * 4 + mask_stride) * height) {
        return error.InvalidIcoData;
    }

    return .{ .width = width, .height = height, .bytes = bytes, .format = .dib };
}

/// Decodes straight RGBA, preserving alpha or the legacy one-bit AND mask.
/// Example: `var image = try frame.decode(gpa); defer image.deinit(gpa);`
pub fn decode(frame: IcoFrame, gpa: std.mem.Allocator) !DecodedImage {
    if (frame.format == .png) {
        var image = try png.decode(gpa, frame.bytes, .{ .max_side = 256, .max_pixels = 256 * 256 });
        errdefer image.deinit(gpa);
        if (image.width != frame.width or image.height != frame.height) {
            return error.InvalidIcoData;
        }

        return image;
    }

    const pixels = try gpa.alloc(u8, frame.width * frame.height * 4);
    const bitmap = frame.bytes[40..][0..pixels.len];
    const mask = frame.bytes[40 + pixels.len ..];
    const stride = frame.width * 4;
    const mask_stride = ((frame.width + 31) / 32) * 4;
    var has_alpha = false;
    var offset: usize = 3;
    while (offset < bitmap.len) : (offset += 4) {
        has_alpha = has_alpha or bitmap[offset] != 0;
    }

    for (0..frame.height) |y| {
        const source_y = frame.height - 1 - y;
        for (0..frame.width) |x| {
            const bgra = bitmap[source_y * stride + x * 4 ..][0..4];
            const hidden = mask[source_y * mask_stride + x / 8] & (@as(u8, 0x80) >> @as(u3, @intCast(x % 8))) != 0;
            const alpha: u8 = if (has_alpha) bgra[3] else if (hidden) 0 else 255;
            pixels[y * stride + x * 4 ..][0..4].* = .{ bgra[2], bgra[1], bgra[0], alpha };
        }
    }

    return .{ .width = frame.width, .height = frame.height, .pixels = pixels };
}

/// Prefers the smallest image covering the cell, otherwise the largest available.
/// Example: `if (candidate.preferredTo(current, cell)) current = candidate;`
pub fn preferredTo(frame: IcoFrame, other: IcoFrame, cell: u32) bool {
    const side = @min(frame.width, frame.height);
    const previous = @min(other.width, other.height);
    if (side >= cell) {
        return previous < cell or side < previous;
    }

    return previous < cell and side > previous;
}

test "32-bit ICO pixels flip bottom-up BGRA and use alpha or the padded legacy mask" {
    var bytes = [_]u8{0} ** 64;
    std.mem.writeInt(u32, bytes[0..4], 40, .little);
    std.mem.writeInt(u32, bytes[4..8], 2, .little);
    std.mem.writeInt(u32, bytes[8..12], 4, .little);
    std.mem.writeInt(u16, bytes[12..14], 1, .little);
    std.mem.writeInt(u16, bytes[14..16], 32, .little);
    bytes[40..56].* = .{ 255, 0, 0, 128, 3, 2, 1, 0, 0, 0, 255, 255, 0, 255, 0, 255 };
    // Top-right is masked; the active alpha channel takes precedence.
    bytes[60] = 0x40;
    const entry = [_]u8{ 2, 2 } ++ [_]u8{0} ** 14;
    const frame = try init(&entry, &bytes);
    const gpa = std.testing.allocator;
    var image = try frame.decode(gpa);
    defer image.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 128, 1, 2, 3, 0 }, image.pixels);

    for (0..4) |index| {
        bytes[43 + index * 4] = 0;
    }

    var legacy = try frame.decode(gpa);
    defer legacy.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 0, 0, 0, 255, 255, 1, 2, 3, 255 }, legacy.pixels);
    try std.testing.expectError(error.InvalidIcoData, init(&entry, bytes[0..63]));
    std.mem.writeInt(u32, bytes[4..8], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.InvalidIcoData, init(&entry, &bytes));
    std.mem.writeInt(u32, bytes[4..8], 2, .little);
    std.mem.writeInt(u16, bytes[14..16], 8, .little);
    try std.testing.expectError(error.UnsupportedIco, init(&entry, &bytes));
}
