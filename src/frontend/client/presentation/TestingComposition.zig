const TestingComposition = @This();
const source_namespace = @import("view.zig");
const ui = @import("../../ui/root.zig");
const theme_mod = @import("../../ui/root.zig").theme;
const workspace_capability = @import("../../workspace/root.zig");
model: *source_namespace.multiplexer.Model,
screen: *source_namespace.term.Screen,
area: ui.Rect,
palette: *const theme_mod.Palette = &theme_mod.default_theme.palette,
bottom_reservation: ?workspace_capability.layout.PaneBottomReservation = null,
