const core = @import("telar-core");
const AcknowledgeFrame = @This();

pane_id: core.PaneId,
frame_id: u64,
received_at_ns: u64,
