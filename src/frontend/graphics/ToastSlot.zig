const IdType = @import("telar-client").Id;
const ToastRenderKey = @import("ToastRenderKey.zig");
const OutputPlacementType = @import("kitty_protocol").OutputPlacement;
const Slot = @This();

id: IdType = .invalid,
pixels: []u8 = &.{},
width: u32 = 0,
height: u32 = 0,
key: ?ToastRenderKey = null,
failed_key: ?ToastRenderKey = null,
placement: ?OutputPlacementType = null,
emitted_placement: ?OutputPlacementType = null,
visible: bool = false,
image_dirty: bool = false,
image_emitted: bool = false,
transfer_offset: usize = 0,
transfer_key: ?ToastRenderKey = null,
