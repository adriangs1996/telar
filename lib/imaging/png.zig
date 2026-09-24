//! A bounded PNG decoder for workspace favicons and pasted images. Wuffs
//! parses and decodes; this file reads the dimensions from the IHDR, which
//! PNG requires to be the first chunk, and rejects them against `PngLimits`
//! before Wuffs allocates a pixel buffer. Runs in workers, never on the
//! interactive path.
const std = @import("std");
const wuffs = @import("wuffs");
const PngHeader = @import("PngHeader.zig");
const DecodedImage = @import("DecodedImage.zig");
const PngTestSpec = @import("PngTestSpec.zig");

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
/// once its CRC matches.
fn dimensions(bytes: []const u8) Error!struct { u32, u32 } {
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

// --- test-only encoder ---------------------------------------------------

fn writeChunk(out: *std.Io.Writer, kind: []const u8, data: []const u8) !void {
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try out.writeInt(u32, @intCast(data.len), .big);
    try out.writeAll(kind);
    try out.writeAll(data);
    try out.writeInt(u32, crc.final(), .big);
}

// Filters one scanline the way an encoder would, so the decoder's inverse
// is checked against independent arithmetic.
fn filterRow(kind: u8, bpp: u8, rows: [2][]const u8) [64]u8 {
    const previous = rows[0];
    const pixels = rows[1];
    var out: [64]u8 = undefined;
    for (pixels, 0..) |value, i| {
        const left: u8 = if (i >= bpp) pixels[i - bpp] else 0;
        const up: u8 = if (previous.len != 0) previous[i] else 0;
        const corner: u8 = if (previous.len != 0 and i >= bpp) previous[i - bpp] else 0;
        out[i] = switch (kind) {
            0 => value,
            1 => value -% left,
            2 => value -% up,
            3 => value -% @as(u8, @intCast((@as(u16, left) + up) / 2)),
            4 => value -% paeth(left, up, corner),
            else => unreachable,
        };
    }

    return out;
}

/// Test-only encoder shared with the worker tests.
/// Example: `const bytes = try png.encodeForTest(gpa, .{ .header = header }, samples);`
pub fn encodeForTest(allocator: std.mem.Allocator, spec: PngTestSpec, samples: []const u8) ![]u8 {
    const stride = spec.header.stride();
    const raw = try allocator.alloc(u8, (stride + 1) * spec.header.height);
    defer allocator.free(raw);
    for (0..spec.header.height) |row| {
        const previous: []const u8 = if (row == 0) &.{} else samples[(row - 1) * stride ..][0..stride];
        const filtered = filterRow(spec.filter, spec.header.bytesPerPixel(), .{ previous, samples[row * stride ..][0..stride] });
        raw[row * (stride + 1)] = spec.filter;
        @memcpy(raw[row * (stride + 1) + 1 ..][0..stride], filtered[0..stride]);
    }

    var compressed: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    defer compressed.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&compressed.writer, &window, .zlib, .default);
    try compress.writer.writeAll(raw);
    try compress.finish();

    var file: std.Io.Writer.Allocating = .init(allocator);
    errdefer file.deinit();
    try file.writer.writeAll(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], spec.header.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], spec.header.height, .big);
    ihdr[8] = spec.depth orelse spec.header.depth;
    ihdr[9] = @intFromEnum(spec.header.color);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = spec.interlace;
    try writeChunk(&file.writer, "IHDR", &ihdr);
    if (spec.palette.len != 0) {
        try writeChunk(&file.writer, "PLTE", spec.palette);
    }

    if (spec.transparency.len != 0) {
        try writeChunk(&file.writer, "tRNS", spec.transparency);
    }

    // Two IDAT chunks prove concatenation.
    const half = compressed.written().len / 2;
    try writeChunk(&file.writer, "IDAT", compressed.written()[0..half]);
    try writeChunk(&file.writer, "IDAT", compressed.written()[half..]);
    try writeChunk(&file.writer, "IEND", &.{});
    return file.toOwnedSlice();
}

fn paeth(left: u8, up: u8, corner: u8) u8 {
    const estimate = @as(i16, left) + up - corner;
    const to_left = @abs(estimate - left);
    const to_up = @abs(estimate - up);
    const to_corner = @abs(estimate - corner);
    if (to_left <= to_up and to_left <= to_corner) {
        return left;
    }

    return if (to_up <= to_corner) up else corner;
}

const rgba_samples = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 10, 20, 30, 40 } ++ [_]u8{ 1, 2, 3, 4, 250, 240, 230, 220, 100, 100, 100, 100, 0, 0, 0, 255 };

test "16-bit RGB and RGBA reconstruct all filters before reducing samples to RGBA8" {
    const allocator = std.testing.allocator;
    const rgba = [_]u8{ 255, 1, 0, 255, 128, 13, 64, 7, 0, 255, 255, 0, 32, 129, 0, 255 } ++
        [_]u8{ 10, 200, 20, 100, 30, 50, 255, 255, 1, 128, 2, 64, 3, 32, 128, 0 };
    const rgb = [_]u8{ 255, 1, 0, 255, 128, 13, 0, 255, 255, 0, 32, 129 } ++
        [_]u8{ 10, 200, 20, 100, 30, 50, 1, 128, 2, 64, 3, 32 };
    const expected_rgba = [_]u8{ 255, 0, 128, 64, 0, 255, 32, 0, 10, 20, 30, 255, 1, 2, 3, 128 };
    const expected_rgb = [_]u8{ 255, 0, 128, 255, 0, 255, 32, 255, 10, 20, 30, 255, 1, 2, 3, 255 };
    for ([_]PngHeader.ColorType{ .rgb, .rgba }) |color| {
        for (0..5) |filter| {
            const samples: []const u8 = if (color == .rgba) &rgba else &rgb;
            const bytes = try encodeForTest(allocator, .{ .header = .{ .width = 2, .height = 2, .color = color, .depth = 16 }, .filter = @intCast(filter) }, samples);
            defer allocator.free(bytes);
            var image = try decode(allocator, bytes, .{});
            defer image.deinit(allocator);
            try std.testing.expectEqualSlices(u8, if (color == .rgba) &expected_rgba else &expected_rgb, image.pixels);
            try std.testing.expectError(error.PngTooLarge, decode(allocator, bytes, .{ .max_pixels = 3 }));
        }
    }
}

test "16-bit PNG rejects short scanlines and invalid palette depth" {
    const allocator = std.testing.allocator;
    const short = try encodeForTest(allocator, .{ .header = .{ .width = 2, .height = 2, .color = .rgba }, .depth = 16 }, rgba_samples[0..16]);
    defer allocator.free(short);
    try std.testing.expectError(error.InvalidPngData, decode(allocator, short, .{}));

    const palette = try encodeForTest(allocator, .{ .header = .{ .width = 2, .height = 2, .color = .palette }, .depth = 16 }, &.{ 0, 0, 0, 0 });
    defer allocator.free(palette);
    try std.testing.expectError(error.InvalidPngData, decode(allocator, palette, .{}));
}

test "decodes an RGBA image with the Paeth filter and an RGB image with the Sub filter" {
    const allocator = std.testing.allocator;
    const rgba = try encodeForTest(allocator, .{ .header = .{ .width = 4, .height = 2, .color = .rgba }, .filter = 4 }, &rgba_samples);
    defer allocator.free(rgba);
    var image = try decode(allocator, rgba, .{});
    defer image.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqualSlices(u8, &rgba_samples, image.pixels);

    const rgb_samples = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255 } ++ [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2, 1 };
    const rgb = try encodeForTest(allocator, .{ .header = .{ .width = 3, .height = 2, .color = .rgb }, .filter = 1 }, &rgb_samples);
    defer allocator.free(rgb);
    var opaque_image = try decode(allocator, rgb, .{});
    defer opaque_image.deinit(allocator);
    const expected = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 9, 8, 7, 255, 6, 5, 4, 255, 3, 2, 1, 255 };
    try std.testing.expectEqualSlices(u8, &expected, opaque_image.pixels);
    try std.testing.expectEqual(@as(u32, 12), opaque_image.view().stride);
}

test "decodes every filter type and a palette with transparency" {
    const allocator = std.testing.allocator;
    for ([_]u8{ 0, 2, 3 }) |filter| {
        const bytes = try encodeForTest(allocator, .{ .header = .{ .width = 4, .height = 2, .color = .rgba }, .filter = filter }, &rgba_samples);
        defer allocator.free(bytes);
        var image = try decode(allocator, bytes, .{});
        defer image.deinit(allocator);
        try std.testing.expectEqualSlices(u8, &rgba_samples, image.pixels);
    }

    const indices = [_]u8{ 0, 1, 2, 1 };
    const bytes = try encodeForTest(allocator, .{
        .header = .{ .width = 2, .height = 2, .color = .palette },
        .filter = 1,
        .palette = &.{ 10, 20, 30, 40, 50, 60, 70, 80, 90 },
        .transparency = &.{ 255, 128 },
    }, &indices);
    defer allocator.free(bytes);
    var image = try decode(allocator, bytes, .{});
    defer image.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255, 40, 50, 60, 128, 70, 80, 90, 255, 40, 50, 60, 128 }, image.pixels);
}

test "rejects interlaced, oversized, invalid-depth, corrupt and non-PNG input without allocating pixels" {
    const allocator = std.testing.allocator;
    const interlaced = try encodeForTest(allocator, .{ .header = .{ .width = 2, .height = 2, .color = .rgba }, .interlace = 1 }, rgba_samples[0..16]);
    defer allocator.free(interlaced);
    try std.testing.expectError(error.InvalidPngData, decode(allocator, interlaced, .{}));

    const deep = try encodeForTest(allocator, .{ .header = .{ .width = 2, .height = 2, .color = .rgba }, .depth = 4 }, rgba_samples[0..16]);
    defer allocator.free(deep);
    try std.testing.expectError(error.InvalidPngData, decode(allocator, deep, .{}));

    const wide = try encodeForTest(allocator, .{ .header = .{ .width = 8, .height = 1, .color = .rgba } }, &rgba_samples);
    defer allocator.free(wide);
    try std.testing.expectError(error.PngTooLarge, decode(allocator, wide, .{ .max_side = 4 }));
    try std.testing.expectError(error.PngTooLarge, decode(allocator, wide, .{ .max_pixels = 7 }));
    var image = try decode(allocator, wide, .{ .max_pixels = 8 });
    image.deinit(allocator);

    const corrupt = try allocator.dupe(u8, wide);
    defer allocator.free(corrupt);
    corrupt[signature.len + 8] ^= 1;
    try std.testing.expectError(error.InvalidPngData, decode(allocator, corrupt, .{}));
    try std.testing.expectError(error.InvalidPngData, decode(allocator, wide[0 .. wide.len - 20], .{}));
    try std.testing.expectError(error.NotPng, decode(allocator, "not a png at all, just some bytes that are long enough", .{}));

    // A stream claiming one row but inflating to two stops at the bound.
    var lying = try encodeForTest(allocator, .{ .header = .{ .width = 4, .height = 2, .color = .rgba } }, &rgba_samples);
    defer allocator.free(lying);
    std.mem.writeInt(u32, lying[signature.len + 8 + 4 ..][0..4], 1, .big);
    var crc = std.hash.Crc32.init();
    crc.update(lying[signature.len + 4 ..][0..17]);
    std.mem.writeInt(u32, lying[signature.len + 21 ..][0..4], crc.final(), .big);
    try std.testing.expectError(error.InvalidPngData, decode(allocator, lying, .{}));
}

/// Bounds a PNG must satisfy before any pixel buffer is allocated.
const PngLimits = struct {
    /// Largest width or height accepted.
    max_side: u32 = 4096,
    /// Largest width times height accepted; the decoded RGBA is four times it.
    max_pixels: u32 = 1 << 20,
};
