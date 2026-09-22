const core = @import("telar-core");
const PaneCommit = @This();

pane_id: core.PaneId,
frame_id: u64,
attached: bool,
attachment_generation: u64 = 0,
