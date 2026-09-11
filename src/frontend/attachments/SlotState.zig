const SlotState = @This();
const source_namespace = @import("delivery.zig");
image_id: u32,
thumbnail: source_namespace.PlacementState,
modal: source_namespace.PlacementState,
image_emitted: bool = false,
image_dirty: bool = true,
transfer_offset: usize = 0,
