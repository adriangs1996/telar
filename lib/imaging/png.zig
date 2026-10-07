//! A bounded PNG decoder for workspace favicons and pasted images. Wuffs
//! parses and decodes; this file reads the dimensions from the IHDR, which
//! PNG requires to be the first chunk, and rejects them against `PngLimits`
//! before Wuffs allocates a pixel buffer. Runs in workers, never on the
//! interactive path.
const std = @import("std");
const wuffs = @import("wuffs");
const DecodedImage = @import("DecodedImage.zig");

pub const Error = error{
    NotPng,
    PngTooLarge,
    InvalidPngData,
    OutOfMemory,
};

const signature = "\x89PNG\r\n\x1a\n";
const ihdr_length = 13;
/// Signature, then the IHDR chunk: length, type, data and CRC.
const header_bytes = signature.len + 4 + 4 + ihdr_length + 4;

/// Decodes `bytes` into straight RGBA. The caller owns the result.
/// Example: `var image = try png.decode(gpa, bytes, .{}); defer image.deinit(gpa);`
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: PngLimits) Error!DecodedImage {
    const width, const height = try dimensions(bytes);
    if (width == 0 or height == 0) {
        return error.InvalidPngData;
    }

    if (width > limits.max_side or height > limits.max_side or @as(u64, width) * height > limits.max_pixels) {
        return error.PngTooLarge;
    }

    const image = wuffs.png.decode(allocator, bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Overflow => error.PngTooLarge,
        error.WuffsError => error.InvalidPngData,
    };

    // Wuffs reads the same IHDR; a disagreement means the checks above did
    // not bound what was allocated.
    if (image.width != width or image.height != height) {
        allocator.free(image.data);
        return error.InvalidPngData;
    }

    return .{
        .width = image.width,
        .height = image.height,
        .pixels = image.data,
    };
}

/// The width and height of the IHDR that must open every PNG, trusted only
/// once its CRC matches. A caller that `decode` refused with `PngTooLarge`
/// reads what the file asked for here, without decoding it.
/// Example: `const width, const height = try png.dimensions(bytes);`
pub fn dimensions(bytes: []const u8) Error!struct { u32, u32 } {
    if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..signature.len], signature)) {
        return error.NotPng;
    }

    const chunk = bytes[signature.len..];
    if (std.mem.readInt(u32, chunk[0..4], .big) != ihdr_length or !std.mem.eql(u8, chunk[4..8], "IHDR")) {
        return error.InvalidPngData;
    }

    const crc = std.mem.readInt(u32, chunk[8 + ihdr_length ..][0..4], .big);
    if (crc != std.hash.Crc32.hash(chunk[4 .. 8 + ihdr_length])) {
        return error.InvalidPngData;
    }

    return .{ std.mem.readInt(u32, chunk[8..12], .big), std.mem.readInt(u32, chunk[12..16], .big) };
}

/// Bounds a PNG must satisfy before any pixel buffer is allocated.
const PngLimits = struct {
    /// Largest width or height accepted.
    max_side: u32 = 4096,
    /// Largest width times height accepted; the decoded RGBA is four times it.
    max_pixels: u32 = 1 << 20,
};
