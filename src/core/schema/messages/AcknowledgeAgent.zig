/// Marks one exact agent generation as seen so a `done` status returns to
/// `ready`. A stale generation is ignored by the runtime.
const AcknowledgeAgent = @This();
const source_namespace = @import("agent.zig");
pane_id: source_namespace.PaneId,
pane_generation: u64,
