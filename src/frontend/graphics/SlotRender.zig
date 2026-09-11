const SlotRender = @This();
const Slot = @import("ToastSlot.zig");
const notifications = @import("telar-client").notifications;
const RenderKey = @import("ToastRenderKey.zig");
slot: *Slot,
item: *const notifications.Item,
key: RenderKey,
