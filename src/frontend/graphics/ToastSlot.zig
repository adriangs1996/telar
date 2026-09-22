const data = @import("model");
const kitty_protocol = @import("kitty_protocol");
const ToastRenderKey = @import("ToastRenderKey.zig");
const Slot = @This();

id: data.NotificationId = .invalid,
pixels: []u8 = &.{},
width: u32 = 0,
height: u32 = 0,
key: ?ToastRenderKey = null,
failed_key: ?ToastRenderKey = null,
placement: ?kitty_protocol.OutputPlacement = null,
emitted_placement: ?kitty_protocol.OutputPlacement = null,
visible: bool = false,
image_dirty: bool = false,
image_emitted: bool = false,
transfer_offset: usize = 0,
transfer_key: ?ToastRenderKey = null,
