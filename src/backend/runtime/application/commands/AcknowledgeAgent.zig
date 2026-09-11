const AcknowledgeAgent = @This();
const source_namespace = @import("acknowledge_agent.zig");
pane_id: source_namespace.schema.PaneId,
pane_generation: u64,
now_ms: i64,
