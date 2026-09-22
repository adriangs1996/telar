const client = @import("telar-client");
const core = @import("telar-core");
const data = @import("model");
const ScreenType = @import("../presentation/Screen.zig");
const TestingComposition = @This();

model: *client.MultiplexerModel,
screen: *ScreenType,
area: core.Rect,
palette: *const client.Palette = &client.theme_support.default_theme.palette,
copy: ?client.CopyProjection = null,
bottom_reservation: ?data.PaneBottomReservation = null,
force: bool = false,
