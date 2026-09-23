const kitty_protocol = @import("kitty_protocol");
const presentation = @import("presentation.zig");
const std = @import("std");
const kitty_codec = @import("../graphics/kitty_codec.zig");
const SlotState = @This();

image_id: u32,
thumbnail: PlacementState,
modal: PlacementState,
image_emitted: bool = false,
image_dirty: bool = true,
transfer_offset: usize = 0,

const PlacementState = struct {
    id: u32,
    z: i32,
    desired: ?kitty_protocol.OutputPlacement = null,
    emitted: ?kitty_protocol.OutputPlacement = null,

    pub fn wanted(self: *const PlacementState) bool {
        return self.desired != null;
    }

    pub fn damaged(self: *const PlacementState) bool {
        return !presentation.optionalPlacementEql(self.desired, self.emitted);
    }

    pub fn write(self: *PlacementState, writer: *std.Io.Writer, image_id: u32) std.Io.Writer.Error!usize {
        if (!self.damaged()) {
            return 0;
        }

        var written: usize = 0;
        if (self.emitted != null) {
            written += try kitty_protocol.writeDeletePlacement(writer, image_id, self.id);
        }

        if (self.desired) |desired| {
            written += try kitty_codec.writeUiPlacement(writer, .{
                .image_id = image_id,
                .placement_id = self.id,
                .value = desired,
                .z = self.z,
            });
        }

        self.emitted = self.desired;

        return written;
    }
};
