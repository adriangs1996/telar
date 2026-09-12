const RectType = @import("telar-core").Rect;
const PaletteType = @import("telar-client").Palette;
const Input = @This();

area: RectType,
names: []const []const u8,
focused: usize,
palette: *const PaletteType,
