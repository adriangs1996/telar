const Preparation = @This();
const source_namespace = @import("toast.zig");
const notifications = @import("telar-client").notifications;
const theme = @import("../ui/root.zig").theme;
const ui_icons = @import("../ui/root.zig").icons;
area: source_namespace.ui.Rect,
center: *const notifications.Center,
palette: *const theme.Palette,
icon_theme: ui_icons.Theme = .unicode,
