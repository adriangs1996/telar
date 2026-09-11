const CompositionInput = @This();
const source_namespace = @import("multiplexer.zig");
const theme = @import("../ui/root.zig").theme;
const CopyProjection = @import("telar-client").workspace.multiplexer.CopyProjection;
const layout_mod = @import("telar-client").workspace.layout;
area: source_namespace.ui.Rect,
palette: *const theme.Palette,
copy: ?CopyProjection = null,
bottom_reservation: ?layout_mod.PaneBottomReservation = null,
progress_animation_frame: u8 = 0,
force: bool = false,
