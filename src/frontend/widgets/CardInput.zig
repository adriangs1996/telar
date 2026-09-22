const core = @import("telar-core");
const data = @import("model");
const CardInput = @This();

area: core.Rect,
item: *const data.NotificationItem,
paint: bool,
