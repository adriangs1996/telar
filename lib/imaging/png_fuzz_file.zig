//! PNG files the imaging fuzz roots write: the byte layout `png.decode`
//! reads before Wuffs, chunks with their CRC, and complete images of zero
//! samples in every color type and bit depth the PNG specification allows,
//! interlaced or not. It carries the PNG root's prefix, which the ICO root
//! follows, to stay inside the fuzz roots' names.

const std = @import("std");

pub const signature = "\x89PNG\r\n\x1a\n";

/// A chunk's length and type before its data, and its CRC after.
pub const chunk_head_bytes = 8;
pub const chunk_crc_bytes = 4;
pub const ihdr_data_bytes = 13;

/// Color types by their IHDR value, as the PNG specification numbers them.
const ColorType = enum(u8) {
    gray = 0,
    rgb = 2,
    palette = 3,
    gray_alpha = 4,
    rgba = 6,

    fn channels(self: ColorType) u8 {
        return switch (self) {
            .gray, .palette => 1,
            .gray_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }
};

/// A color type and one of the bit depths the specification allows it.
const ColorDepth = struct {
    color: ColorType,
    depth: u8,
};

fn colorDepth(color: ColorType, depth: u8) ColorDepth {
    return .{
        .color = color,
        .depth = depth,
    };
}

/// Every color type and bit depth pair a PNG may declare.
pub const color_depths = [_]ColorDepth{
    colorDepth(.gray, 1),
    colorDepth(.gray, 2),
    colorDepth(.gray, 4),
    colorDepth(.gray, 8),
    colorDepth(.gray, 16),
    colorDepth(.rgb, 8),
    colorDepth(.rgb, 16),
    colorDepth(.palette, 1),
    colorDepth(.palette, 2),
    colorDepth(.palette, 4),
    colorDepth(.palette, 8),
    colorDepth(.gray_alpha, 8),
    colorDepth(.gray_alpha, 16),
    colorDepth(.rgba, 8),
    colorDepth(.rgba, 16),
};

/// The image a zero-sample PNG declares.
const ZeroImage = struct {
    width: u32,
    height: u32,
    color_depth: ColorDepth,
    interlaced: bool,
};

/// The origin and step of one Adam7 pass, in pixels.
const Pass = struct {
    x: u32,
    y: u32,
    step_x: u32,
    step_y: u32,
};

const adam7_passes = [_]Pass{
    .{
        .x = 0,
        .y = 0,
        .step_x = 8,
        .step_y = 8,
    },
    .{
        .x = 4,
        .y = 0,
        .step_x = 8,
        .step_y = 8,
    },
    .{
        .x = 0,
        .y = 4,
        .step_x = 4,
        .step_y = 8,
    },
    .{
        .x = 2,
        .y = 0,
        .step_x = 4,
        .step_y = 4,
    },
    .{
        .x = 0,
        .y = 2,
        .step_x = 2,
        .step_y = 4,
    },
    .{
        .x = 1,
        .y = 0,
        .step_x = 2,
        .step_y = 2,
    },
    .{
        .x = 0,
        .y = 1,
        .step_x = 1,
        .step_y = 2,
    },
};

const bits_per_byte = 8;
const max_palette_entries = 256;
const palette_entry_bytes = 3;

/// The compressor needs an output buffer to start with, as in
/// `png.encodeForTest`.
const compressed_initial_capacity = 4096;

/// Offsets of the IHDR fields a zero-sample PNG sets, inside the chunk's data.
const ihdr_width_offset = 0;
const ihdr_height_offset = 4;
const ihdr_depth_offset = 8;
const ihdr_color_offset = 9;
const ihdr_interlace_offset = 12;

/// Writes one chunk: length, type, data and the CRC of type and data.
/// Example: `try png_file.writeChunk(&out, "IEND", &.{});`
pub fn writeChunk(out: *std.Io.Writer, kind: []const u8, data: []const u8) !void {
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try out.writeInt(
        u32,
        @intCast(data.len),
        .big,
    );
    try out.writeAll(kind);
    try out.writeAll(data);
    try out.writeInt(
        u32,
        crc.final(),
        .big,
    );
}

fn ceilDiv(dividend: usize, divisor: usize) usize {
    return std.math.divCeil(
        usize,
        dividend,
        divisor,
    ) catch unreachable;
}

/// Pixels of one side of an Adam7 pass over `side` pixels: those from
/// `origin` on, every `step`.
fn passSide(side: u32, origin: u32, step: u32) u32 {
    if (side <= origin) {
        return 0;
    }

    return @intCast(ceilDiv(side - origin, step));
}

/// Bytes of the filtered scanlines of a `width` x `height` pass, filter
/// bytes included; an empty pass has none.
fn passBytes(image: ZeroImage, width: u32, height: u32) usize {
    if (width == 0 or height == 0) {
        return 0;
    }

    const bits = @as(usize, width) * image.color_depth.color.channels() * image.color_depth.depth;
    return @as(usize, height) * (1 + ceilDiv(bits, bits_per_byte));
}

/// Bytes of the decompressed image data: one pass, or the seven Adam7 ones.
fn rawBytes(image: ZeroImage) usize {
    if (!image.interlaced) {
        return passBytes(
            image,
            image.width,
            image.height,
        );
    }

    var total: usize = 0;
    for (adam7_passes) |pass| {
        const width = passSide(
            image.width,
            pass.x,
            pass.step_x,
        );
        const height = passSide(
            image.height,
            pass.y,
            pass.step_y,
        );
        total += passBytes(
            image,
            width,
            height,
        );
    }

    return total;
}

fn writeBig(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(
        u32,
        bytes,
        value,
        .big,
    );
}

/// A complete, valid PNG whose samples, filter bytes and palette are all
/// zero, so every color type and bit depth decodes it. The caller owns it.
/// Example: `const bytes = try png_file.zeroPng(gpa, .{ .width = 64, .height = 16, .color_depth = depth, .interlaced = true });`
pub fn zeroPng(gpa: std.mem.Allocator, image: ZeroImage) ![]u8 {
    const raw = try gpa.alloc(u8, rawBytes(image));
    defer gpa.free(raw);
    @memset(raw, 0);

    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, compressed_initial_capacity);
    defer compressed.deinit();

    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(
        &compressed.writer,
        &window,
        .zlib,
        .default,
    );
    try compress.writer.writeAll(raw);
    try compress.finish();

    var file: std.Io.Writer.Allocating = .init(gpa);
    errdefer file.deinit();

    try file.writer.writeAll(signature);
    var ihdr: [ihdr_data_bytes]u8 = @splat(0);
    writeBig(ihdr[ihdr_width_offset..][0..4], image.width);
    writeBig(ihdr[ihdr_height_offset..][0..4], image.height);
    ihdr[ihdr_depth_offset] = image.color_depth.depth;
    ihdr[ihdr_color_offset] = @intFromEnum(image.color_depth.color);
    ihdr[ihdr_interlace_offset] = @intFromBool(image.interlaced);
    try writeChunk(
        &file.writer,
        "IHDR",
        &ihdr,
    );

    if (image.color_depth.color == .palette) {
        var palette: [max_palette_entries * palette_entry_bytes]u8 = @splat(0);
        const entries = @as(usize, 1) << @intCast(image.color_depth.depth);
        try writeChunk(
            &file.writer,
            "PLTE",
            palette[0 .. entries * palette_entry_bytes],
        );
    }

    try writeChunk(
        &file.writer,
        "IDAT",
        compressed.written(),
    );
    try writeChunk(
        &file.writer,
        "IEND",
        &.{},
    );
    return file.toOwnedSlice();
}

test "Adam7 passes of a zero image cover exactly its pixels" {
    for (color_depths) |color_depth| {
        const image: ZeroImage = .{
            .width = 13,
            .height = 11,
            .color_depth = color_depth,
            .interlaced = true,
        };
        var pixels: usize = 0;
        for (adam7_passes) |pass| {
            const width = passSide(
                image.width,
                pass.x,
                pass.step_x,
            );
            const height = passSide(
                image.height,
                pass.y,
                pass.step_y,
            );
            pixels += @as(usize, width) * height;
        }

        try std.testing.expectEqual(@as(usize, image.width) * image.height, pixels);
        try std.testing.expect(rawBytes(image) > 0);
    }
}
