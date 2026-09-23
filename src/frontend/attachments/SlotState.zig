const PlacementState = @import("PlacementState.zig");
const SlotState = @This();

image_id: u32,
thumbnail: PlacementState,
modal: PlacementState,
image_emitted: bool = false,
image_dirty: bool = true,
transfer_offset: usize = 0,
