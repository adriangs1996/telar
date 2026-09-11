const PaneIdType = @import("telar-core").PaneId;
const AcknowledgeFrame = @This();

pane_id: PaneIdType,
frame_id: u64,
received_at_ns: u64,
