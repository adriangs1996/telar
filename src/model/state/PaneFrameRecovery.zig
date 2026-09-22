const core = @import("telar-core");
const PaneFrameRecovery = @This();

pane_id: core.PaneId,
known_frame_id: u64,
