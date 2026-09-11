//! Frontend policy adapter over the dependency-free Kitty protocol encoder.

const std = @import("std");
const TransmissionChunks = @import("TransmissionChunks.zig");
const ChunkProgress = @import("kitty_protocol").ChunkProgress;
const writeTransmissionChunks_module = @import("kitty_protocol").writeTransmissionChunks;
const PngTransmissionChunks = @import("PngTransmissionChunks.zig");
const writePngTransmissionChunks_module = @import("kitty_protocol").writePngTransmissionChunks;
const Transmission = @import("Transmission.zig");
const writeTransmission_module = @import("kitty_protocol").writeTransmission;
const SharedTransmission = @import("SharedTransmission.zig");
const writeSharedTransmission_module = @import("kitty_protocol").writeSharedTransmission;
const PlacementCommand = @import("PlacementCommand.zig");
const writePlacement_module = @import("kitty_protocol").writePlacement;
const ImageType = @import("telar-core").Image;
const KittyProtocolImage = @import("kitty_protocol").Image;

pub const transmission_budget_per_frame: usize = 256 * 1024;

/// Emits transmission chunks under the frontend's existing image vocabulary.
/// For example: `try writeTransmissionChunks(writer, transmission)`.
pub fn writeTransmissionChunks(writer: *std.Io.Writer, transmission: TransmissionChunks) std.Io.Writer.Error!ChunkProgress {
    return writeTransmissionChunks_module(writer, .{
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
pub fn writePngTransmissionChunks(writer: *std.Io.Writer, transmission: PngTransmissionChunks) std.Io.Writer.Error!ChunkProgress {
    return writePngTransmissionChunks_module(writer, .{
        .image_id = transmission.external_id,
        .png = transmission.png,
        .start_offset = transmission.start_offset,
        .budget = transmission.budget,
    });
}

/// Emits one complete raw frontend image transmission.
/// For example: `try writeTransmission(writer, transmission)`.
pub fn writeTransmission(writer: *std.Io.Writer, transmission: Transmission) std.Io.Writer.Error!usize {
    return writeTransmission_module(writer, .{
        .image_id = transmission.external_id,
        .image = protocolImage(transmission.image),
        .pixels = transmission.pixels,
    });
}

/// Emits one shared-memory frontend image transmission.
/// For example: `try writeSharedTransmission(writer, transmission)`.
pub fn writeSharedTransmission(writer: *std.Io.Writer, transmission: SharedTransmission) std.Io.Writer.Error!usize {
    return writeSharedTransmission_module(writer, .{
        .image_id = transmission.external_id,
        .image = protocolImage(transmission.image),
        .name = transmission.name,
    });
}

/// Places a child image within the z-index range available to applications.
/// For example: `try writePlacement(writer, placement)`.
pub fn writePlacement(writer: *std.Io.Writer, placement: PlacementCommand) std.Io.Writer.Error!usize {
    var clamped = placement;
    clamped.z = std.math.clamp(placement.z, -1000, 1000);
    return writePlacementAtZ(writer, clamped);
}

/// Places client chrome above the z-index range available to child images.
/// For example: `try writeUiPlacement(writer, placement)`.
pub fn writeUiPlacement(writer: *std.Io.Writer, placement: PlacementCommand) std.Io.Writer.Error!usize {
    std.debug.assert(placement.z > 1000);
    return writePlacementAtZ(writer, placement);
}

fn writePlacementAtZ(writer: *std.Io.Writer, placement: PlacementCommand) std.Io.Writer.Error!usize {
    return writePlacement_module(writer, .{
        .image_id = placement.image_id,
        .placement_id = placement.placement_id,
        .value = placement.value,
        .z = placement.z,
    });
}

fn protocolImage(image: ImageType) KittyProtocolImage {
    return .{
        .format = switch (image.format) {
            .rgb => .rgb,
            .rgba => .rgba,
        },
        .width = image.width,
        .height = image.height,
    };
}
