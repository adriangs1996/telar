const RenderKey = @This();
const notifications = @import("telar-client").notifications;
const ui_icons = @import("../ui/root.zig").icons;
id: notifications.Id,
level: notifications.Level,
cell_width: u16,
cell_height: u16,
card_columns: u16,
icon_theme: ui_icons.Theme,
background: [3]u8,
accent: [3]u8,
text: [3]u8,
subtext: [3]u8,
