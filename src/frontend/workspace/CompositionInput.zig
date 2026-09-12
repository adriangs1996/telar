const RectType = @import("telar-core").Rect;
const PaletteType = @import("telar-client").Palette;
const CopyProjection = @import("telar-client").CopyProjection;
const PaneBottomReservationType = @import("telar-client").PaneBottomReservation;
const AgentSnapshotType = @import("telar-client").AgentSnapshot;
const CompositionInput = @This();

area: RectType,
palette: *const PaletteType,
copy: ?CopyProjection = null,
bottom_reservation: ?PaneBottomReservationType = null,
progress_animation_frame: u8 = 0,
force: bool = false,
/// Agents shown by thread surfaces and the revision that invalidates them.
agents: ?*const AgentSnapshotType = null,
agents_revision: u64 = 0,
