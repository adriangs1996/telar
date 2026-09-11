const RectType = @import("telar-core").Rect;
const PaletteType = @import("../ui/Palette.zig");
const Input = @This();

area: RectType,
names: []const []const u8,
focused: usize,
palette: *const PaletteType,
