const PaneIdType = @import("telar-core").PaneId;
const PaneProgressStateType = @import("telar-core").PaneProgressState;
const PaneProjection = @This();

pane_id: PaneIdType,
cols: u16,
rows: u16,
scroll_offset: u32,
graphics_placeholder: bool,
progress_state: PaneProgressStateType,
progress_percent: ?u8,
