const data = @import("model");
const client = @import("telar-client");
const RenderKey = @This();

id: data.NotificationId,
level: data.NotificationLevel,
cell_width: u16,
cell_height: u16,
card_columns: u16,
icon_theme: client.Theme,
background: [3]u8,
accent: [3]u8,
text: [3]u8,
subtext: [3]u8,
