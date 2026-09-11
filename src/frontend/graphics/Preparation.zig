const RectType = @import("telar-core").Rect;
const CenterType = @import("telar-client").Center;
const PaletteType = @import("../ui/Palette.zig");
const ThemeType = @import("telar-client").Theme;
const Preparation = @This();

area: RectType,
center: *const CenterType,
palette: *const PaletteType,
icon_theme: ThemeType = .unicode,
