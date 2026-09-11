//! Public entrypoint for kitty_protocol.

pub const ChunkProgress = @import("ChunkProgress.zig");
pub const Image = @import("Image.zig");
pub const OutputPlacement = @import("OutputPlacement.zig");
pub const writeDeleteImage = @import("deletion.zig").writeDeleteImage;
pub const writeDeleteImageRange = @import("deletion.zig").writeDeleteImageRange;
pub const writeDeletePlacement = @import("deletion.zig").writeDeletePlacement;
pub const writePlacement = @import("placement.zig").writePlacement;
pub const writePngTransmissionChunks = @import("transmission_support.zig").writePngTransmissionChunks;
pub const writeSharedTransmission = @import("transmission_support.zig").writeSharedTransmission;
pub const writeTransmission = @import("transmission_support.zig").writeTransmission;
pub const writeTransmissionAbort = @import("transmission_support.zig").writeTransmissionAbort;
pub const writeTransmissionChunks = @import("transmission_support.zig").writeTransmissionChunks;

test {
    _ = @import("deletion.zig");
    _ = @import("placement.zig");
    _ = @import("transmission_support.zig");
}
