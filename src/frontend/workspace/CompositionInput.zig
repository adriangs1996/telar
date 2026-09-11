const RectType = @import("telar-core").Rect;
const PaletteType = @import("../ui/Palette.zig");
const CopyProjection = @import("telar-client").CopyProjection;
const PaneBottomReservationType = @import("telar-client").PaneBottomReservation;
const CompositionInput = @This();

area: RectType,
palette: *const PaletteType,
copy: ?CopyProjection = null,
bottom_reservation: ?PaneBottomReservationType = null,
progress_animation_frame: u8 = 0,
force: bool = false,
