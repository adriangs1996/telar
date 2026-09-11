const IdType = @import("telar-client").Id;
const LevelType = @import("telar-client").Level;
const ThemeType = @import("telar-client").Theme;
const RenderKey = @This();

id: IdType,
level: LevelType,
cell_width: u16,
cell_height: u16,
card_columns: u16,
icon_theme: ThemeType,
background: [3]u8,
accent: [3]u8,
text: [3]u8,
subtext: [3]u8,
