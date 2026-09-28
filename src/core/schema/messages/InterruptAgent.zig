const id = @import("../id.zig");
/// Sends the agent's declared interrupt keys to one exact pane generation,
/// only while the agent is working.
const InterruptAgent = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
