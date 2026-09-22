const core = @import("telar-core");
const CopyModeFrame = @This();

pane_id: core.PaneId,
previous_offset: u32,
scroll: core.Scroll,
