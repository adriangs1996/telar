//! Frontend policy adapter over the dependency-free Kitty protocol encoder.

const std = @import("std");
const core = @import("telar-core");
const protocol = @import("kitty_protocol");

const Io = std.Io;
const graphics = core.graphics;

pub const transmission_budget_per_frame: usize = 256 * 1024;
pub const OutputPlacement = protocol.OutputPlacement;
pub const ChunkProgress = protocol.ChunkProgress;

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

pub const PlacementCommand = struct {
    image_id: u32,
    placement_id: u32,
    value: OutputPlacement,
    z: i32,
};

/// Emits transmission chunks under the frontend's existing image vocabulary.
/// For example: `try writeTransmissionChunks(writer, transmission)`.
pub fn writeTransmissionChunks(writer: *Io.Writer, transmission: TransmissionChunks) Io.Writer.Error!ChunkProgress {
    return protocol.writeTransmissionChunks(writer, .{
        .image_id = transmission.external_id,
        .image = protocolImage(transmission.image),
        .pixels = transmission.pixels,
        .start_offset = transmission.start_offset,
        .budget = transmission.budget,
        .compressed = transmission.compressed,
    });
}

/// Emits PNG chunks under the frontend's external image identity.
/// For example: `try writePngTransmissionChunks(writer, transmission)`.
pub fn writePngTransmissionChunks(writer: *Io.Writer, transmission: PngTransmissionChunks) Io.Writer.Error!ChunkProgress {
    return protocol.writePngTransmissionChunks(writer, .{
        .image_id = transmission.external_id,
        .png = transmission.png,
        .start_offset = transmission.start_offset,
        .budget = transmission.budget,
    });
}

/// Emits one complete raw frontend image transmission.
/// For example: `try writeTransmission(writer, transmission)`.
pub fn writeTransmission(writer: *Io.Writer, transmission: Transmission) Io.Writer.Error!usize {
    return protocol.writeTransmission(writer, .{
        .image_id = transmission.external_id,
        .image = protocolImage(transmission.image),
        .pixels = transmission.pixels,
    });
}

/// Emits one shared-memory frontend image transmission.
/// For example: `try writeSharedTransmission(writer, transmission)`.
pub fn writeSharedTransmission(writer: *Io.Writer, transmission: SharedTransmission) Io.Writer.Error!usize {
    return protocol.writeSharedTransmission(writer, .{
        .image_id = transmission.external_id,
        .image = protocolImage(transmission.image),
        .name = transmission.name,
    });
}

pub const writeTransmissionAbort = protocol.writeTransmissionAbort;

/// Places a child image within the z-index range available to applications.
/// For example: `try writePlacement(writer, placement)`.
pub fn writePlacement(writer: *Io.Writer, placement: PlacementCommand) Io.Writer.Error!usize {
    var clamped = placement;
    clamped.z = std.math.clamp(placement.z, -1000, 1000);
    return writePlacementAtZ(writer, clamped);
}

/// Places client chrome above the z-index range available to child images.
/// For example: `try writeUiPlacement(writer, placement)`.
pub fn writeUiPlacement(writer: *Io.Writer, placement: PlacementCommand) Io.Writer.Error!usize {
    std.debug.assert(placement.z > 1000);
    return writePlacementAtZ(writer, placement);
}

pub const writeDeleteImage = protocol.writeDeleteImage;
pub const writeDeletePlacement = protocol.writeDeletePlacement;
pub const writeDeleteImageRange = protocol.writeDeleteImageRange;

fn writePlacementAtZ(writer: *Io.Writer, placement: PlacementCommand) Io.Writer.Error!usize {
    return protocol.writePlacement(writer, .{
        .image_id = placement.image_id,
        .placement_id = placement.placement_id,
        .value = placement.value,
        .z = placement.z,
    });
}

fn protocolImage(image: graphics.Image) protocol.Image {
    return .{
        .format = switch (image.format) {
            .rgb => .rgb,
            .rgba => .rgba,
        },
        .width = image.width,
        .height = image.height,
    };
}
