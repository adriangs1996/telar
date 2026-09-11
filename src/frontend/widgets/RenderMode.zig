const RenderMode = @This();
const ui = @import("../ui/root.zig");
const notifications = @import("telar-client").notifications;
area: ui.Rect,
center: *const notifications.Center,
paint: bool,
