const PendingPaneFocus = @This();
const core = @import("telar-core");
const source_namespace = @import("session_support.zig");
request_id: core.schema.RequestId,
pane_id: core.schema.PaneId,
pane_generation: u64,
target: source_namespace.Key,
