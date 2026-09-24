//! A done agent stays done until the client that focuses its pane
//! acknowledges it once; then it returns to ready.
const agent_status = @import("agent_status.zig");

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");

/// Acknowledges one agent's completed turn.
///
/// ```zig
/// agent_done.acknowledge(model, request);
/// ```
pub fn acknowledge(model: *RuntimeModel, request: core.AcknowledgeAgent) void {
    const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
    const result = agent_status.acknowledge(model, .{ .id = request.pane_id, .generation = request.pane_generation }, now_ms);

    if (result == .unknown_agent) {
        model.metrics.stale_client_messages += 1;
    }
}
