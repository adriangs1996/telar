const OutputPlacementType = @import("kitty_protocol").OutputPlacement;
const presentation = @import("presentation.zig");
const std = @import("std");
const writeDeletePlacement_module = @import("kitty_protocol").writeDeletePlacement;
const kitty_codec = @import("../graphics/kitty_codec.zig");
const PlacementState = @This();

id: u32,
z: i32,
desired: ?OutputPlacementType = null,
emitted: ?OutputPlacementType = null,

pub fn wanted(placement: *const PlacementState) bool {
    return placement.desired != null;
}

pub fn damaged(placement: *const PlacementState) bool {
    return !presentation.optionalPlacementEql(placement.desired, placement.emitted);
}

pub fn write(placement: *PlacementState, writer: *std.Io.Writer, image_id: u32) std.Io.Writer.Error!usize {
    if (!placement.damaged()) {
        return 0;
    }

    var written: usize = 0;
    if (placement.emitted != null) {
        written += try writeDeletePlacement_module(writer, image_id, placement.id);
    }

    if (placement.desired) |desired| {
        written += try kitty_codec.writeUiPlacement(writer, .{
            .image_id = image_id,
            .placement_id = placement.id,
            .value = desired,
            .z = placement.z,
        });
    }

    placement.emitted = placement.desired;

    return written;
}
