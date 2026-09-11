const RectType = @import("telar-core").Rect;
const ItemType = @import("telar-client").NotificationItem;
const CardInput = @This();

area: RectType,
item: *const ItemType,
paint: bool,
