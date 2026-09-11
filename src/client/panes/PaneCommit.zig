const PaneIdType = @import("telar-core").PaneId;
const PaneCommit = @This();

pane_id: PaneIdType,
frame_id: u64,
attached: bool,
attachment_generation: u64 = 0,
