const std = @import("std");
const shared = @import("../graphics.zig");
const id = @import("id.zig");
const wire = @import("wire.zig");

pub const PaneId = id.PaneId;

pub const SnapshotPhase = enum(u8) { begin = 0, end = 1 };

pub const Snapshot = struct {
    pane_id: PaneId,
    revision: u64,
    phase: SnapshotPhase,
};

pub const Image = struct {
    pane_id: PaneId,
    revision: u64,
    image: shared.Image,
};

pub const ImageChunk = struct {
    pane_id: PaneId,
    revision: u64,
    key: shared.ImageKey,
    offset: u64,
    bytes: []const u8,
};

pub const Placement = struct {
    pane_id: PaneId,
    revision: u64,
    placement: shared.Placement,
};

pub const DeleteImage = struct {
    pane_id: PaneId,
    revision: u64,
    key: shared.ImageKey,
};

pub const DeletePlacement = struct {
    pane_id: PaneId,
    revision: u64,
    key: shared.ImageKey,
    virtual_id: u64,
    placement_id: u32,
};

pub fn encodeSnapshot(e: *wire.Encoder, value: Snapshot) !void {
    try header(e, value.pane_id, value.revision);
    try e.writeByte(@intFromEnum(value.phase));
}

pub fn decodeSnapshot(d: *wire.Decoder) !Snapshot {
    const h = try decodeHeader(d);
    return .{
        .pane_id = h.pane_id,
        .revision = h.revision,
        .phase = switch (try d.readByte()) {
            0 => .begin,
            1 => .end,
            else => return error.InvalidGraphicsSnapshotPhase,
        },
    };
}

pub fn encodeImage(e: *wire.Encoder, value: Image) !void {
    _ = try value.image.validate(shared.max_image_bytes_per_pane);
    try header(e, value.pane_id, value.revision);
    try imageKey(e, value.image.key);
    try e.writeByte(@intFromEnum(value.image.format));
    try e.writeInt(u32, value.image.width);
    try e.writeInt(u32, value.image.height);
    try e.writeInt(u64, value.image.byte_len);
}

pub fn decodeImage(d: *wire.Decoder) !Image {
    const h = try decodeHeader(d);
    const value: Image = .{
        .pane_id = h.pane_id,
        .revision = h.revision,
        .image = .{
            .key = try decodeImageKey(d),
            .format = switch (try d.readByte()) {
                24 => .rgb,
                32 => .rgba,
                else => return error.UnsupportedGraphicsFormat,
            },
            .width = try d.readInt(u32),
            .height = try d.readInt(u32),
            .byte_len = try d.readInt(u64),
        },
    };
    _ = try value.image.validate(shared.max_image_bytes_per_pane);
    return value;
}

pub fn encodeImageChunk(e: *wire.Encoder, value: ImageChunk) !void {
    if (value.bytes.len == 0 or value.bytes.len > shared.max_ipc_chunk_bytes)
        return error.InvalidGraphicsChunkLength;
    try header(e, value.pane_id, value.revision);
    try imageKey(e, value.key);
    try e.writeInt(u64, value.offset);
    try e.writeSized32(value.bytes);
}

pub fn decodeImageChunk(d: *wire.Decoder) !ImageChunk {
    const h = try decodeHeader(d);
    const value: ImageChunk = .{
        .pane_id = h.pane_id,
        .revision = h.revision,
        .key = try decodeImageKey(d),
        .offset = try d.readInt(u64),
        .bytes = try d.readSized32(),
    };
    if (value.bytes.len == 0 or value.bytes.len > shared.max_ipc_chunk_bytes)
        return error.InvalidGraphicsChunkLength;
    return value;
}

pub fn encodePlacement(e: *wire.Encoder, value: Placement) !void {
    try header(e, value.pane_id, value.revision);
    const p = value.placement;
    if (p.virtual_id == 0) return error.InvalidGraphicsIdentity;
    try imageKey(e, p.key);
    try e.writeInt(u64, p.virtual_id);
    try e.writeInt(u32, p.placement_id);
    try e.writeInt(i32, p.x);
    try e.writeInt(i32, p.y);
    try e.writeInt(u32, p.source_x);
    try e.writeInt(u32, p.source_y);
    try e.writeInt(u32, p.source_width);
    try e.writeInt(u32, p.source_height);
    try e.writeInt(u32, p.columns);
    try e.writeInt(u32, p.rows);
    try e.writeInt(u32, p.offset_x);
    try e.writeInt(u32, p.offset_y);
    try e.writeInt(i32, p.z_index);
}

pub fn decodePlacement(d: *wire.Decoder) !Placement {
    const h = try decodeHeader(d);
    return .{
        .pane_id = h.pane_id,
        .revision = h.revision,
        .placement = .{
            .key = try decodeImageKey(d),
            .virtual_id = try decodeVirtualId(d),
            .placement_id = try d.readInt(u32),
            .x = try d.readInt(i32),
            .y = try d.readInt(i32),
            .source_x = try d.readInt(u32),
            .source_y = try d.readInt(u32),
            .source_width = try d.readInt(u32),
            .source_height = try d.readInt(u32),
            .columns = try d.readInt(u32),
            .rows = try d.readInt(u32),
            .offset_x = try d.readInt(u32),
            .offset_y = try d.readInt(u32),
            .z_index = try d.readInt(i32),
        },
    };
}

pub fn encodeDeleteImage(e: *wire.Encoder, value: DeleteImage) !void {
    try header(e, value.pane_id, value.revision);
    try imageKey(e, value.key);
}

pub fn decodeDeleteImage(d: *wire.Decoder) !DeleteImage {
    const h = try decodeHeader(d);
    return .{ .pane_id = h.pane_id, .revision = h.revision, .key = try decodeImageKey(d) };
}

pub fn encodeDeletePlacement(e: *wire.Encoder, value: DeletePlacement) !void {
    if (value.virtual_id == 0) return error.InvalidGraphicsIdentity;
    try header(e, value.pane_id, value.revision);
    try imageKey(e, value.key);
    try e.writeInt(u64, value.virtual_id);
    try e.writeInt(u32, value.placement_id);
}

pub fn decodeDeletePlacement(d: *wire.Decoder) !DeletePlacement {
    const h = try decodeHeader(d);
    return .{
        .pane_id = h.pane_id,
        .revision = h.revision,
        .key = try decodeImageKey(d),
        .virtual_id = try decodeVirtualId(d),
        .placement_id = try d.readInt(u32),
    };
}

fn decodeVirtualId(d: *wire.Decoder) !u64 {
    const virtual_id = try d.readInt(u64);
    if (virtual_id == 0) return error.InvalidGraphicsIdentity;
    return virtual_id;
}

fn header(e: *wire.Encoder, pane_id: PaneId, revision: u64) !void {
    if (pane_id == .invalid or revision == 0) return error.InvalidGraphicsIdentity;
    try e.writeInt(u64, id.raw(pane_id));
    try e.writeInt(u64, revision);
}

fn decodeHeader(d: *wire.Decoder) !struct { pane_id: PaneId, revision: u64 } {
    const pane_id = try id.pane(try d.readInt(u64));
    const revision = try d.readInt(u64);
    if (revision == 0) return error.InvalidGraphicsIdentity;
    return .{ .pane_id = pane_id, .revision = revision };
}

fn imageKey(e: *wire.Encoder, key: shared.ImageKey) !void {
    if (key.image_id == 0 or key.generation == 0) return error.InvalidGraphicsIdentity;
    try e.writeInt(u32, key.image_id);
    try e.writeInt(u64, key.generation);
}

fn decodeImageKey(d: *wire.Decoder) !shared.ImageKey {
    const key: shared.ImageKey = .{
        .image_id = try d.readInt(u32),
        .generation = try d.readInt(u64),
    };
    if (key.image_id == 0 or key.generation == 0) return error.InvalidGraphicsIdentity;
    return key;
}

test "graphics image metadata and chunks round trip" {
    var bytes: [256]u8 = undefined;
    var encoder = wire.Encoder.init(&bytes);
    const image: Image = .{
        .pane_id = @enumFromInt(1),
        .revision = 3,
        .image = .{
            .key = .{ .image_id = 7, .generation = 8 },
            .format = .rgba,
            .width = 2,
            .height = 2,
            .byte_len = 16,
        },
    };
    try encodeImage(&encoder, image);
    var decoder = wire.Decoder.init(encoder.finish());
    try std.testing.expectEqualDeep(image, try decodeImage(&decoder));
    try decoder.ensureEnd();
}

test "graphics IPC chunks have an explicit upper bound" {
    var bytes: [128]u8 = undefined;
    var encoder = wire.Encoder.init(&bytes);
    const oversized = @as([*]const u8, @ptrFromInt(1))[0 .. shared.max_ipc_chunk_bytes + 1];
    try std.testing.expectError(error.InvalidGraphicsChunkLength, encodeImageChunk(&encoder, .{
        .pane_id = @enumFromInt(1),
        .revision = 1,
        .key = .{ .image_id = 1, .generation = 1 },
        .offset = 0,
        .bytes = oversized,
    }));
}
