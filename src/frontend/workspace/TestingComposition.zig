const MultiplexerModel = @import("telar-client").MultiplexerModel;
const ScreenType = @import("../presentation/Screen.zig");
const RectType = @import("telar-core").Rect;
const PaletteType = @import("telar-client").Palette;
const theme = @import("telar-client").theme_support;
const CopyProjection = @import("telar-client").CopyProjection;
const PaneBottomReservationType = @import("telar-client").PaneBottomReservation;
const TestingComposition = @This();

model: *MultiplexerModel,
screen: *ScreenType,
area: RectType,
palette: *const PaletteType = &theme.default_theme.palette,
copy: ?CopyProjection = null,
bottom_reservation: ?PaneBottomReservationType = null,
force: bool = false,
