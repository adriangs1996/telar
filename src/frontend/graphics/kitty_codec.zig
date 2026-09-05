//! Stateless Kitty wire encoding; no store, workspace or sidebar dependencies.

const std = @import("std");
const core = @import("telar-core");
const graphics = core.graphics;
const Io = std.Io;

pub const transmission_budget_per_frame: usize = 256 * 1024;

pub const OutputPlacement = struct {
    column: u32,
    row: u32,
    offset_x: u32,
    offset_y: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    columns: u32,
    rows: u32,
};

fn printCounted(writer: *Io.Writer, comptime format: []const u8, args: anytype) Io.Writer.Error!usize {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch unreachable;
    try writer.writeAll(text);
    return text.len;
}

pub const ChunkProgress = struct { written: usize, offset: usize };

pub const TransmissionChunks = struct {
    external_id: u32,
    image: graphics.Image,
    pixels: []const u8,
    start_offset: usize,
    budget: usize,
    compressed: bool,
};

pub const PngTransmissionChunks = struct {
    external_id: u32,
    png: []const u8,
    start_offset: usize,
    budget: usize,
};

pub const Transmission = struct {
    external_id: u32,
    image: graphics.Image,
    pixels: []const u8,
};

pub const SharedTransmission = struct {
    external_id: u32,
    image: graphics.Image,
    name: []const u8,
};

/// Emits transmission chunks for `pixels` starting at byte `start_offset`,
/// spending roughly `budget` encoded bytes. Always makes progress: at least
/// one chunk goes out even under a zero budget, so a caller looping on the
/// offset cannot stall. `offset == pixels.len` in the result means the final
/// `m=0` chunk went out and the transfer is closed.
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
            written += try printCounted(writer, "\x1b_Ga=t,f={d},s={d},v={d},t=d,i={d},q=2{s},m={d};", .{
                @intFromEnum(transmission.image.format), transmission.image.width,                    transmission.image.height,
                transmission.external_id,                if (transmission.compressed) ",o=z" else "", @intFromBool(more),
            });
        } else {
            written += try printCounted(writer, "\x1b_Gm={d};", .{@intFromBool(more)});
        }
        try writer.writeAll(payload);
        try writer.writeAll("\x1b\\");
        written += payload.len + 2;
        offset += take;
    }
    return .{ .written = written, .offset = offset };
}

/// Emits an already encoded PNG using Kitty's direct-data transport. PNG is
/// the one encoded format the protocol standardizes (`f=100`), so local
/// clipboard previews can stay compressed in client memory and on the wire.
/// For example: `try writePngTransmissionChunks(writer, transmission)`.
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
            written += try printCounted(
                writer,
                "\x1b_Ga=t,f=100,t=d,i={d},q=2,m={d};",
                .{ transmission.external_id, @intFromBool(more) },
            );
        } else {
            written += try printCounted(writer, "\x1b_Gm={d};", .{@intFromBool(more)});
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
        .external_id = transmission.external_id,
        .image = transmission.image,
        .pixels = transmission.pixels,
        .start_offset = 0,
        .budget = std.math.maxInt(usize),
        .compressed = false,
    });
    return progress.written;
}

/// Hands the host a shared object's name. Unlike every other pane escape it
/// asks for a reply (`q=0`): the host's `OK` is the consume signal that
/// retires the image, and an error reclaims the name at once.
/// For example: `try writeSharedTransmission(writer, transmission)`.
pub fn writeSharedTransmission(writer: *Io.Writer, transmission: SharedTransmission) Io.Writer.Error!usize {
    const Encoder = std.base64.standard.Encoder;
    var encoded: [128]u8 = undefined;
    const payload = Encoder.encode(encoded[0..Encoder.calcSize(transmission.name.len)], transmission.name);
    var written = try printCounted(
        writer,
        "\x1b_Ga=t,f={d},s={d},v={d},t=s,i={d},q=0;",
        .{ @intFromEnum(transmission.image.format), transmission.image.width, transmission.image.height, transmission.external_id },
    );
    try writer.writeAll(payload);
    try writer.writeAll("\x1b\\");
    written += payload.len + 2;
    return written;
}

/// Closes an interrupted chunked transfer with an empty final chunk. The
/// terminal discards the short payload; q=2 on the header keeps it silent.
pub fn writeTransmissionAbort(writer: *Io.Writer) Io.Writer.Error!usize {
    const closing = "\x1b_Gm=0;\x1b\\";
    try writer.writeAll(closing);
    return closing.len;
}

pub const PlacementCommand = struct {
    image_id: u32,
    placement_id: u32,
    value: OutputPlacement,
    z: i32,
};

/// Places a child image within the z-index range available to applications.
/// For example: `try writePlacement(writer, command)`.
pub fn writePlacement(writer: *Io.Writer, command: PlacementCommand) Io.Writer.Error!usize {
    var clamped = command;
    clamped.z = std.math.clamp(command.z, -1000, 1000);
    return writePlacementAtZ(writer, clamped);
}

/// Places client chrome above the z-index range available to child
/// applications. Callers must use a fixed client-owned z value.
/// For example: `try writeUiPlacement(writer, command)`.
pub fn writeUiPlacement(writer: *Io.Writer, command: PlacementCommand) Io.Writer.Error!usize {
    std.debug.assert(command.z > 1000);
    return writePlacementAtZ(writer, command);
}

fn writePlacementAtZ(writer: *Io.Writer, command: PlacementCommand) Io.Writer.Error!usize {
    const value = command.value;
    var written = try printCounted(writer, "\x1b[{d};{d}H", .{ value.row + 1, value.column + 1 });
    written += try printCounted(
        writer,
        "\x1b_Ga=p,i={d},p={d},x={d},y={d},w={d},h={d},c={d},r={d},X={d},Y={d},z={d},C=1,q=2\x1b\\",
        .{ command.image_id, command.placement_id, value.source_x, value.source_y, value.source_width, value.source_height, value.columns, value.rows, value.offset_x, value.offset_y, command.z },
    );
    return written;
}

pub fn writeDeleteImage(writer: *Io.Writer, image_id: u32) Io.Writer.Error!usize {
    return printCounted(writer, "\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{image_id});
}

pub fn writeDeletePlacement(writer: *Io.Writer, image_id: u32, placement_id: u32) Io.Writer.Error!usize {
    return printCounted(writer, "\x1b_Ga=d,d=i,i={d},p={d},q=2\x1b\\", .{ image_id, placement_id });
}

pub fn writeDeleteImageRange(writer: *Io.Writer, first: u32, last: u32) Io.Writer.Error!usize {
    return printCounted(writer, "\x1b_Ga=d,d=R,x={d},y={d},q=2\x1b\\", .{ first, last });
}

test "PNG transmissions use encoded format without raw pixel dimensions" {
    var output: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&output);
    const progress = try writePngTransmissionChunks(&writer, .{
        .external_id = 0x90000001,
        .png = "encoded png bytes",
        .start_offset = 0,
        .budget = transmission_budget_per_frame,
    });
    try std.testing.expectEqual(@as(usize, 17), progress.offset);
    const bytes = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "a=t,f=100,t=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, ",s=") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, ",v=") == null);
}
