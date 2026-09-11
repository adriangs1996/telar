const PaneIdType = @import("telar-core").PaneId;
const ScrollType = @import("telar-core").Scroll;
const CopyModeFrame = @This();

pane_id: PaneIdType,
previous_offset: u32,
scroll: ScrollType,
