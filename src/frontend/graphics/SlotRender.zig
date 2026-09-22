const data = @import("model");
const ToastSlot = @import("ToastSlot.zig");
const ToastRenderKey = @import("ToastRenderKey.zig");
const SlotRender = @This();

slot: *ToastSlot,
item: *const data.NotificationItem,
key: ToastRenderKey,
