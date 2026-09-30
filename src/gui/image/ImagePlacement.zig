//! One Kitty graphics placement resolved for drawing: its layer and paint
//! order, the texture it samples and its box relative to its anchor cell.
//! The anchor row is relative to the top of the pane's active screen; the
//! renderer adds the pane's scroll and origin each frame.
const core = @import("telar-core");
const kitty_protocol = @import("kitty_protocol");
const ImagePlacement = @This();

pane_id: core.PaneId,
layer: kitty_protocol.Layer,
z_index: i32,
image_id: u32,
generation: u64,
virtual_id: u64,
/// The texture to sample; its own image's, or a previous generation's
/// while the new one uploads.
handle: u32,
column: i32,
row: i32,
box: kitty_protocol.DisplayBox,
/// u0, v0, u1, v1 inside the texture.
uv: [4]f32,

/// Paint order: pane, then layer, then z-index, then image id, then the
/// placement, so a lower image id draws below on equal z as the spec asks.
/// Example: `std.mem.sort(ImagePlacement, list, {}, ImagePlacement.lessThan);`.
pub fn lessThan(_: void, left: ImagePlacement, right: ImagePlacement) bool {
    if (left.pane_id != right.pane_id) {
        return @intFromEnum(left.pane_id) < @intFromEnum(right.pane_id);
    }

    if (left.layer != right.layer) {
        return @intFromEnum(left.layer) < @intFromEnum(right.layer);
    }

    if (left.z_index != right.z_index) {
        return left.z_index < right.z_index;
    }

    if (left.image_id != right.image_id) {
        return left.image_id < right.image_id;
    }

    return left.virtual_id < right.virtual_id;
}
