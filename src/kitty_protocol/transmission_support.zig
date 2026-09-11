//! Direct, PNG and shared-memory Kitty image transmission encoding.

const std = @import("std");
const command = @import("command.zig");
const image_mod = @import("image_support.zig");

const Io = std.Io;
pub const Image = image_mod.Image;

pub const ChunkProgress = @import("ChunkProgress.zig");

pub const TransmissionChunks = @import("TransmissionChunks.zig");

pub const PngTransmissionChunks = @import("PngTransmissionChunks.zig");

pub const Transmission = @import("Transmission.zig");

pub const SharedTransmission = @import("SharedTransmission.zig");

/// Emits direct-data chunks starting at `start_offset` and stops after roughly
/// `budget` encoded bytes. At least one chunk is written when data remains.
/// For example: `try writeTransmissionChunks(writer, transmission)`.
pub fn writeTransmissionChunks(writer: *Io.Writer, transmission: TransmissionChunks) Io.Writer.Error!ChunkProgress {
    const Encoder = std.base64.standard.Encoder;
    const raw_chunk_size = 3072;
    var encoded: [4096]u8 = undefined;
    var offset = transmission.start_offset;
    var written: usize = 0;

    while (offset < transmission.pixels.len) {
        if (written != 0 and written >= transmission.budget) {
            break;
        }

        const take = @min(raw_chunk_size, transmission.pixels.len - offset);
        const payload = Encoder.encode(encoded[0..Encoder.calcSize(take)], transmission.pixels[offset..][0..take]);
        const more = offset + take < transmission.pixels.len;

        if (offset == 0) {
            written += try command.print(writer, "\x1b_Ga=t,f={d},s={d},v={d},t=d,i={d},q=2{s},m={d};", .{
                @intFromEnum(transmission.image.format), transmission.image.width,                    transmission.image.height,
                transmission.image_id,                   if (transmission.compressed) ",o=z" else "", @intFromBool(more),
            });
        } else {
            written += try command.print(writer, "\x1b_Gm={d};", .{@intFromBool(more)});
        }

        try writer.writeAll(payload);
        try writer.writeAll("\x1b\\");
        written += payload.len + 2;
        offset += take;
    }

    return .{ .written = written, .offset = offset };
}

/// Emits PNG chunks starting at `start_offset` and stops after roughly
/// `budget` encoded bytes. For example: `try writePngTransmissionChunks(writer, transmission)`.
pub fn writePngTransmissionChunks(writer: *Io.Writer, transmission: PngTransmissionChunks) Io.Writer.Error!ChunkProgress {
    const Encoder = std.base64.standard.Encoder;
    const raw_chunk_size = 3072;
    var encoded: [4096]u8 = undefined;
    var offset = transmission.start_offset;
    var written: usize = 0;

    while (offset < transmission.png.len) {
        if (written != 0 and written >= transmission.budget) {
            break;
        }

        const take = @min(raw_chunk_size, transmission.png.len - offset);
        const payload = Encoder.encode(encoded[0..Encoder.calcSize(take)], transmission.png[offset..][0..take]);
        const more = offset + take < transmission.png.len;

        if (offset == 0) {
            written += try command.print(
                writer,
                "\x1b_Ga=t,f=100,t=d,i={d},q=2,m={d};",
                .{ transmission.image_id, @intFromBool(more) },
            );
        } else {
            written += try command.print(writer, "\x1b_Gm={d};", .{@intFromBool(more)});
        }

        try writer.writeAll(payload);
        try writer.writeAll("\x1b\\");
        written += payload.len + 2;
        offset += take;
    }

    return .{ .written = written, .offset = offset };
}

/// Emits one complete raw image transmission.
/// For example: `try writeTransmission(writer, transmission)`.
pub fn writeTransmission(writer: *Io.Writer, transmission: Transmission) Io.Writer.Error!usize {
    const progress = try writeTransmissionChunks(writer, .{
        .image_id = transmission.image_id,
        .image = transmission.image,
        .pixels = transmission.pixels,
        .start_offset = 0,
        .budget = std.math.maxInt(usize),
        .compressed = false,
    });

    return progress.written;
}

/// Emits a shared-memory image transmission and requests a terminal response.
/// For example: `try writeSharedTransmission(writer, transmission)`.
pub fn writeSharedTransmission(writer: *Io.Writer, transmission: SharedTransmission) Io.Writer.Error!usize {
    const Encoder = std.base64.standard.Encoder;
    var encoded: [128]u8 = undefined;
    const payload = Encoder.encode(encoded[0..Encoder.calcSize(transmission.name.len)], transmission.name);
    var written = try command.print(
        writer,
        "\x1b_Ga=t,f={d},s={d},v={d},t=s,i={d},q=0;",
        .{ @intFromEnum(transmission.image.format), transmission.image.width, transmission.image.height, transmission.image_id },
    );
    try writer.writeAll(payload);
    try writer.writeAll("\x1b\\");
    written += payload.len + 2;

    return written;
}

/// Closes an interrupted chunked transfer with an empty final chunk.
/// For example: `try writeTransmissionAbort(writer)`.
pub fn writeTransmissionAbort(writer: *Io.Writer) Io.Writer.Error!usize {
    const closing = "\x1b_Gm=0;\x1b\\";
    try writer.writeAll(closing);
    return closing.len;
}

test "direct transmission chunks raw pixels without changing them" {
    var pixels: [3073]u8 = undefined;
    for (&pixels, 0..) |*byte, index| {
        byte.* = @truncate(index);
    }

    var output: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    _ = try writeTransmission(&writer, .{
        .image_id = 9,
        .image = .{ .format = .rgba, .width = 3073, .height = 1 },
        .pixels = &pixels,
    });

    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "\x1b_Ga=t,f=32,s=3073,v=1,t=d,i=9,q=2,m=1;"));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b\\\x1b_Gm=0;") != null);
}

test "PNG transmission omits raw pixel dimensions" {
    var output: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    const progress = try writePngTransmissionChunks(&writer, .{
        .image_id = 0x90000001,
        .png = "encoded png bytes",
        .start_offset = 0,
        .budget = std.math.maxInt(usize),
    });

    try std.testing.expectEqual(@as(usize, 17), progress.offset);
    const bytes = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "a=t,f=100,t=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, ",s=") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, ",v=") == null);
}
