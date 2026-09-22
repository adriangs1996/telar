const core = @import("telar-core");
const client = @import("telar-client");
const data = @import("model");
const CompositionInput = @This();

area: core.Rect,
palette: *const data.Palette,
copy: ?client.CopyProjection = null,
bottom_reservation: ?data.PaneBottomReservation = null,
progress_animation_frame: u8 = 0,
force: bool = false,
/// Agents shown by thread surfaces and the revision that invalidates them.
agents: ?*const data.AgentSnapshot = null,
agents_revision: u64 = 0,
