//! Kitty graphics protocol commands written into a caller buffer: direct,
//! chunked, PNG and shared-memory transmission, placement, deletion and
//! aborting a partial transmission, error replies, the control fields of a
//! received command, and the drawn size and layer of a placement. Nothing
//! here allocates.

const deletion = @import("deletion.zig");
const display = @import("display.zig");
const image_support = @import("image_support.zig");
const placement = @import("placement.zig");
const reply = @import("reply.zig");
const transmission_support = @import("transmission_support.zig");
pub const ChunkProgress = @import("ChunkProgress.zig");
pub const ControlFields = @import("ControlFields.zig");
pub const DisplayBox = @import("DisplayBox.zig");
pub const DisplayCells = @import("DisplayCells.zig");
pub const DisplayRequest = @import("DisplayRequest.zig");
pub const Layer = @import("Layer.zig").Layer;
pub const below_background_limit = display.below_background_limit;
pub const displayBox = display.box;
pub const displayCells = display.cells;
pub const displayLayer = display.layer;
pub const Format = image_support.Format;
pub const ErrorCode = reply.ErrorCode;
pub const Image = @import("Image.zig");
pub const OutputPlacement = @import("OutputPlacement.zig");
pub const writeDeleteImage = deletion.writeDeleteImage;
pub const writeDeleteImageRange = deletion.writeDeleteImageRange;
pub const writeDeletePlacement = deletion.writeDeletePlacement;
pub const writeError = reply.writeError;
pub const writePlacement = placement.writePlacement;
pub const writePngTransmissionChunks = transmission_support.writePngTransmissionChunks;
pub const writeSharedTransmission = transmission_support.writeSharedTransmission;
pub const writeTransmission = transmission_support.writeTransmission;
pub const writeTransmissionAbort = transmission_support.writeTransmissionAbort;
pub const writeTransmissionChunks = transmission_support.writeTransmissionChunks;

test {
    _ = @import("ControlField.zig");
    _ = @import("ControlFields.zig");
    _ = @import("deletion.zig");
    _ = @import("display.zig");
    _ = @import("image_support.zig");
    _ = @import("placement.zig");
    _ = @import("reply.zig");
    _ = @import("transmission_support.zig");
}
