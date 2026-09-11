const CardInput = @This();
const ui = @import("../ui/root.zig");
const notifications = @import("telar-client").notifications;
area: ui.Rect,
item: *const notifications.Item,
paint: bool,
