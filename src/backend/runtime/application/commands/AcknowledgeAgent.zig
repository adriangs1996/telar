const core = @import("telar-core");
const AcknowledgeAgent = @This();

pane_id: core.PaneId,
pane_generation: u64,
now_ms: i64,
