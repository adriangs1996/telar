//! A bounded PNG decoder for workspace favicons: 8-bit, non-interlaced,
//! colour types 2 (RGB), 6 (RGBA) and 3 (palette with optional tRNS),
//! inflated by `std.compress.flate` and unfiltered row by row. Every
//! dimension is checked against `PngLimits` before a buffer is allocated,
//! and the inflated stream may not exceed the exact scanline size, so a
//! small file cannot expand past the bound. Runs in the favicon worker,
//! never on the interactive path.
const std = @import("std");
const flate = std.compress.flate;
const PngHeader = @import("PngHeader.zig");
const PngPalette = @import("PngPalette.zig");
const PngImage = @import("PngImage.zig");
const PngLimits = @import("PngLimits.zig");
const PngChunk = @import("PngChunk.zig");
const PngExpansion = @import("PngExpansion.zig");
const PngTestSpec = @import("PngTestSpec.zig");

pub const Error = error{
    NotPng,
    UnsupportedPng,
    PngTooLarge,
    InvalidPngData,
    OutOfMemory,
};

const signature = "\x89PNG\r\n\x1a\n";

/// Decodes `bytes` into straight RGBA. The caller owns the result.
/// Example: `var image = try png.decode(gpa, bytes, .{}); defer image.deinit(gpa);`
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: PngLimits) Error!PngImage {
    if (bytes.len < signature.len + 25 or !std.mem.eql(u8, bytes[0..signature.len], signature)) {
        return error.NotPng;
    }

    var header: ?PngHeader = null;
    var palette: PngPalette = .{};
    var idat_len: usize = 0;
    var cursor: usize = signature.len;
    while (try nextChunk(bytes, &cursor)) |chunk| {
        if (std.mem.eql(u8, chunk.kind, "IHDR")) {
            if (header != null) {
                return error.InvalidPngData;
            }

            header = try parseHeader(chunk.data, limits);
        } else if (std.mem.eql(u8, chunk.kind, "PLTE")) {
            try parsePalette(&palette, chunk.data);
        } else if (std.mem.eql(u8, chunk.kind, "tRNS")) {
            try parseTransparency(&palette, chunk.data);
        } else if (std.mem.eql(u8, chunk.kind, "IDAT")) {
            idat_len += chunk.data.len;
        } else if (std.mem.eql(u8, chunk.kind, "IEND")) {
            break;
        }
    }

    const ihdr = header orelse return error.InvalidPngData;
    if (idat_len == 0 or (ihdr.color == .palette and palette.count == 0)) {
        return error.InvalidPngData;
    }

    const idat = try allocator.alloc(u8, idat_len);
    defer allocator.free(idat);
    try collectImageData(bytes, idat);
    const stride = ihdr.stride();
    const raw = try allocator.alloc(u8, (stride + 1) * ihdr.height);
    defer allocator.free(raw);
    try inflate(idat, raw);
    try unfilter(raw, ihdr);
    const pixels = try allocator.alloc(u8, @as(usize, ihdr.width) * ihdr.height * 4);
    errdefer allocator.free(pixels);
    try expand(raw, ihdr, .{ .palette = &palette, .pixels = pixels });
    return .{ .width = ihdr.width, .height = ihdr.height, .pixels = pixels };
}

// Reads one chunk at `cursor` and verifies its CRC, so a corrupt file is
// rejected before its data is interpreted.
fn nextChunk(bytes: []const u8, cursor: *usize) Error!?PngChunk {
    if (cursor.* == bytes.len) {
        return null;
    }

    if (bytes.len - cursor.* < 12) {
        return error.InvalidPngData;
    }

    const length = std.mem.readInt(u32, bytes[cursor.*..][0..4], .big);
    if (length > bytes.len - cursor.* - 12) {
        return error.InvalidPngData;
    }

    const kind = bytes[cursor.* + 4 ..][0..4];
    const data = bytes[cursor.* + 8 ..][0..length];
    const crc = std.mem.readInt(u32, bytes[cursor.* + 8 + length ..][0..4], .big);
    if (crc != std.hash.Crc32.hash(bytes[cursor.* + 4 ..][0 .. 4 + length])) {
        return error.InvalidPngData;
    }

    cursor.* += 12 + length;
    return .{ .kind = kind, .data = data };
}

fn parseHeader(data: []const u8, limits: PngLimits) Error!PngHeader {
    if (data.len != 13) {
        return error.InvalidPngData;
    }

    const width = std.mem.readInt(u32, data[0..4], .big);
    const height = std.mem.readInt(u32, data[4..8], .big);
    if (width == 0 or height == 0) {
        return error.InvalidPngData;
    }

    if (width > limits.max_side or height > limits.max_side or @as(u64, width) * height > limits.max_pixels) {
        return error.PngTooLarge;
    }

    const depth = data[8];
    const color: PngHeader.ColorType = switch (data[9]) {
        2 => .rgb,
        3 => .palette,
        6 => .rgba,
        else => return error.UnsupportedPng,
    };
    const interlace = data[12];
    if (depth != 8 or interlace != 0 or data[10] != 0 or data[11] != 0) {
        return error.UnsupportedPng;
    }

    return .{ .width = width, .height = height, .color = color };
}

fn parsePalette(palette: *PngPalette, data: []const u8) Error!void {
    if (data.len == 0 or data.len % 3 != 0 or data.len / 3 > PngPalette.max_entries) {
        return error.InvalidPngData;
    }

    palette.count = @intCast(data.len / 3);
    for (0..palette.count) |index| {
        palette.colors[index] = data[index * 3 ..][0..3].*;
    }
}

// Only palette transparency is used; a colour-key tRNS on RGB is ignored.
fn parseTransparency(palette: *PngPalette, data: []const u8) Error!void {
    if (data.len > PngPalette.max_entries) {
        return error.InvalidPngData;
    }

    @memcpy(palette.alphas[0..data.len], data);
}

fn collectImageData(bytes: []const u8, idat: []u8) Error!void {
    var cursor: usize = signature.len;
    var filled: usize = 0;
    while (try nextChunk(bytes, &cursor)) |chunk| {
        if (std.mem.eql(u8, chunk.kind, "IDAT")) {
            @memcpy(idat[filled..][0..chunk.data.len], chunk.data);
            filled += chunk.data.len;
        } else if (std.mem.eql(u8, chunk.kind, "IEND")) {
            break;
        }
    }
}

// Inflates exactly `raw.len` bytes: a stream that would write more fails
// on the fixed writer, so a decompression bomb stops at the scanline bound.
fn inflate(idat: []const u8, raw: []u8) Error!void {
    var input = std.Io.Reader.fixed(idat);
    var decompress = flate.Decompress.init(&input, .zlib, &.{});
    var output = std.Io.Writer.fixed(raw);
    _ = decompress.reader.streamRemaining(&output) catch return error.InvalidPngData;
    if (output.end != raw.len) {
        return error.InvalidPngData;
    }
}

fn unfilter(raw: []u8, header: PngHeader) Error!void {
    const stride = header.stride();
    const bpp = header.bytesPerPixel();
    var previous: ?[]const u8 = null;
    for (0..header.height) |row| {
        const line = raw[row * (stride + 1) ..][0 .. stride + 1];
        const filter = line[0];
        const pixels = line[1..];
        switch (filter) {
            0 => {},
            1 => for (bpp..stride) |i| {
                pixels[i] +%= pixels[i - bpp];
            },
            2 => if (previous) |above| for (0..stride) |i| {
                pixels[i] +%= above[i];
            },
            3 => for (0..stride) |i| {
                const left: u16 = if (i >= bpp) pixels[i - bpp] else 0;
                const up: u16 = if (previous) |above| above[i] else 0;
                pixels[i] +%= @intCast((left + up) / 2);
            },
            4 => for (0..stride) |i| {
                const left: u8 = if (i >= bpp) pixels[i - bpp] else 0;
                const up: u8 = if (previous) |above| above[i] else 0;
                const corner: u8 = if (previous != null and i >= bpp) previous.?[i - bpp] else 0;
                pixels[i] +%= paeth(left, up, corner);
            },
            else => return error.InvalidPngData,
        }

        previous = pixels;
    }
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

fn expand(raw: []const u8, header: PngHeader, out: PngExpansion) Error!void {
    const stride = header.stride();
    const width: usize = header.width;
    for (0..header.height) |row| {
        const line = raw[row * (stride + 1) + 1 ..][0..stride];
        const destination = out.pixels[row * width * 4 ..][0 .. width * 4];
        switch (header.color) {
            .rgba => @memcpy(destination, line),
            .rgb => for (0..width) |x| {
                destination[x * 4 ..][0..3].* = line[x * 3 ..][0..3].*;
                destination[x * 4 + 3] = 255;
            },
            .palette => for (0..width) |x| {
                destination[x * 4 ..][0..4].* = try out.palette.lookup(line[x]);
            },
        }
    }
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

fn encodeForTest(allocator: std.mem.Allocator, spec: PngTestSpec, samples: []const u8) ![]u8 {
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
    var window: [flate.max_window_len]u8 = undefined;
    var compress = try flate.Compress.init(&compressed.writer, &window, .zlib, .default);
    try compress.writer.writeAll(raw);
    try compress.finish();

    var file: std.Io.Writer.Allocating = .init(allocator);
    errdefer file.deinit();
    try file.writer.writeAll(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], spec.header.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], spec.header.height, .big);
    ihdr[8] = spec.depth;
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

const rgba_samples = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 10, 20, 30, 40 } ++ [_]u8{ 1, 2, 3, 4, 250, 240, 230, 220, 100, 100, 100, 100, 0, 0, 0, 255 };

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

test "rejects interlaced, oversized, deep, corrupt and non-PNG input without allocating pixels" {
    const allocator = std.testing.allocator;
    const interlaced = try encodeForTest(allocator, .{ .header = .{ .width = 2, .height = 2, .color = .rgba }, .interlace = 1 }, rgba_samples[0..16]);
    defer allocator.free(interlaced);
    try std.testing.expectError(error.UnsupportedPng, decode(allocator, interlaced, .{}));

    const deep = try encodeForTest(allocator, .{ .header = .{ .width = 2, .height = 2, .color = .rgba }, .depth = 16 }, rgba_samples[0..16]);
    defer allocator.free(deep);
    try std.testing.expectError(error.UnsupportedPng, decode(allocator, deep, .{}));

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
