const ToastSlot = @import("ToastSlot.zig");
const ItemType = @import("telar-client").NotificationItem;
const ToastRenderKey = @import("ToastRenderKey.zig");
const SlotRender = @This();

slot: *ToastSlot,
item: *const ItemType,
key: ToastRenderKey,
