const PlacementState = @This();
const kitty = @import("../graphics/root.zig").kitty;
const source_namespace = @import("presentation.zig");
id: u32,
z: i32,
desired: ?kitty.OutputPlacement = null,
emitted: ?kitty.OutputPlacement = null,

pub fn wanted(placement: *const PlacementState) bool {
    return placement.desired != null;
}

pub fn damaged(placement: *const PlacementState) bool {
    return !source_namespace.optionalPlacementEql(placement.desired, placement.emitted);
}

pub fn write(placement: *PlacementState, writer: *source_namespace.Io.Writer, image_id: u32) source_namespace.Io.Writer.Error!usize {
    if (!placement.damaged()) {
        return 0;
    }

    var written: usize = 0;
    if (placement.emitted != null) {
        written += try kitty.writeDeletePlacement(writer, image_id, placement.id);
    }

    if (placement.desired) |desired| {
        written += try kitty.writeUiPlacement(writer, .{
            .image_id = image_id,
            .placement_id = placement.id,
            .value = desired,
            .z = placement.z,
        });
    }

    placement.emitted = placement.desired;

    return written;
}
