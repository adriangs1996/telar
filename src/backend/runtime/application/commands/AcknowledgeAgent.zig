const PaneIdType = @import("telar-core").PaneId;
const AcknowledgeAgent = @This();

pane_id: PaneIdType,
pane_generation: u64,
now_ms: i64,
