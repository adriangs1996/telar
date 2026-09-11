const id = @import("../id.zig");
/// Marks one exact agent generation as seen so a `done` status returns to
/// `ready`. A stale generation is ignored by the runtime.
const AcknowledgeAgent = @This();

pane_id: id.PaneId,
pane_generation: u64,
