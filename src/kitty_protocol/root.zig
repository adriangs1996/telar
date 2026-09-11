//! Dependency-free Kitty Graphics Protocol command encoding.

const image = @import("image_support.zig");
const transmission = @import("transmission_support.zig");
const placement = @import("placement.zig");
const deletion = @import("deletion.zig");

pub const Format = image.Format;
pub const Image = image.Image;

pub const ChunkProgress = transmission.ChunkProgress;
pub const TransmissionChunks = transmission.TransmissionChunks;
pub const PngTransmissionChunks = transmission.PngTransmissionChunks;
pub const Transmission = transmission.Transmission;
pub const SharedTransmission = transmission.SharedTransmission;
pub const writeTransmissionChunks = transmission.writeTransmissionChunks;
pub const writePngTransmissionChunks = transmission.writePngTransmissionChunks;
pub const writeTransmission = transmission.writeTransmission;
pub const writeSharedTransmission = transmission.writeSharedTransmission;
pub const writeTransmissionAbort = transmission.writeTransmissionAbort;

pub const OutputPlacement = placement.OutputPlacement;
pub const PlacementCommand = placement.PlacementCommand;
pub const writePlacement = placement.writePlacement;

pub const writeDeleteImage = deletion.writeDeleteImage;
pub const writeDeletePlacement = deletion.writeDeletePlacement;
pub const writeDeleteImageRange = deletion.writeDeleteImageRange;

test {
    @import("std").testing.refAllDecls(@This());
}
