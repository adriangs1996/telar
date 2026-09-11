const MultiplexerModel = @import("telar-client").MultiplexerModel;
const ScreenType = @import("../../presentation/Screen.zig");
const RectType = @import("telar-core").Rect;
const PaletteType = @import("../../ui/Palette.zig");
const theme_mod = @import("../../ui/theme_support.zig");
const PaneBottomReservationType = @import("telar-client").PaneBottomReservation;
const TestingComposition = @This();

model: *MultiplexerModel,
screen: *ScreenType,
area: RectType,
palette: *const PaletteType = &theme_mod.default_theme.palette,
bottom_reservation: ?PaneBottomReservationType = null,
