const PaneIdType = @import("telar-core").PaneId;
const PaneProgressStateType = @import("telar-core").PaneProgressState;
const PaneSurfaceType = @import("telar-core").PaneSurface;
const PaneProjection = @This();

pane_id: PaneIdType,
surface: PaneSurfaceType,
cols: u16,
rows: u16,
scroll_offset: u32,
graphics_placeholder: bool,
progress_state: PaneProgressStateType,
progress_percent: ?u8,
