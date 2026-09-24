//! Kitty graphics protocol commands written into a caller buffer: direct,
//! chunked, PNG and shared-memory transmission, placement, deletion and
//! aborting a partial transmission. Nothing here allocates or reads replies.

const deletion = @import("deletion.zig");
const image_support = @import("image_support.zig");
const placement = @import("placement.zig");
const transmission_support = @import("transmission_support.zig");
pub const ChunkProgress = @import("ChunkProgress.zig");
pub const Format = image_support.Format;
pub const Image = @import("Image.zig");
pub const OutputPlacement = @import("OutputPlacement.zig");
pub const writeDeleteImage = deletion.writeDeleteImage;
pub const writeDeleteImageRange = deletion.writeDeleteImageRange;
pub const writeDeletePlacement = deletion.writeDeletePlacement;
pub const writePlacement = placement.writePlacement;
pub const writePngTransmissionChunks = transmission_support.writePngTransmissionChunks;
pub const writeSharedTransmission = transmission_support.writeSharedTransmission;
pub const writeTransmission = transmission_support.writeTransmission;
pub const writeTransmissionAbort = transmission_support.writeTransmissionAbort;
pub const writeTransmissionChunks = transmission_support.writeTransmissionChunks;

test {
    _ = @import("deletion.zig");
    _ = @import("image_support.zig");
    _ = @import("placement.zig");
    _ = @import("transmission_support.zig");
}
