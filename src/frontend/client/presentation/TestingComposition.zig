const MultiplexerModel = @import("telar-client").MultiplexerModel;
const ScreenType = @import("../../presentation/Screen.zig");
const RectType = @import("telar-core").Rect;
const PaletteType = @import("telar-client").Palette;
const theme_mod = @import("telar-client").theme_support;
const PaneBottomReservationType = @import("telar-client").PaneBottomReservation;
const TestingComposition = @This();

model: *MultiplexerModel,
screen: *ScreenType,
area: RectType,
palette: *const PaletteType = &theme_mod.default_theme.palette,
bottom_reservation: ?PaneBottomReservationType = null,
