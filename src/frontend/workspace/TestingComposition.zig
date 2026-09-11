const TestingComposition = @This();
const Model = @import("telar-client").workspace.multiplexer.Model;
const source_namespace = @import("multiplexer.zig");
const theme = @import("../ui/root.zig").theme;
const CopyProjection = @import("telar-client").workspace.multiplexer.CopyProjection;
const layout_mod = @import("telar-client").workspace.layout;
model: *Model,
screen: *source_namespace.term.Screen,
area: source_namespace.ui.Rect,
palette: *const theme.Palette = &theme.default_theme.palette,
copy: ?CopyProjection = null,
bottom_reservation: ?layout_mod.PaneBottomReservation = null,
force: bool = false,
