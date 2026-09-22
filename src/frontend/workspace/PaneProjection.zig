const core = @import("telar-core");
const PaneProjection = @This();

pane_id: core.PaneId,
surface: core.PaneSurface,
cols: u16,
rows: u16,
scroll_offset: u32,
graphics_placeholder: bool,
progress_state: core.PaneProgressState,
progress_percent: ?u8,
