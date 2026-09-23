const client = @import("telar-client");
const core = @import("telar-core");
const data = @import("model");
const ScreenType = @import("../presentation/Screen.zig");
const TestingComposition = @This();

model: *data.ClientModel,
/// The composed tab; tests compose their only tab.
tab: usize = 0,
screen: *ScreenType,
area: core.Rect,
palette: *const data.Palette = &data.theme_support.default_theme.palette,
copy: ?client.CopyProjection = null,
bottom_reservation: ?data.PaneBottomReservation = null,
force: bool = false,
