const TrackerType = @import("../../../agent/Tracker.zig");
const AcknowledgeAgent = @import("AcknowledgeAgent.zig");
const tracker_support = @import("../../../agent/tracker_support.zig");
const PaneKeyType = @import("../../../pane/PaneKey.zig");
const AcknowledgeAgentHandler = @This();

agents: *TrackerType,

/// Resolves the exact pane generation and lets the tracker turn an unseen
/// completion back into `ready`. The tracker revision advances only when
/// the projection changes.
///
/// ```zig
/// const result = handler.execute(.{ .pane_id = pane_id, .pane_generation = 3, .now_ms = now_ms });
/// ```
pub fn execute(handler: *AcknowledgeAgentHandler, command: AcknowledgeAgent) tracker_support.AcknowledgeResult {
    const key: PaneKeyType = .{
        .id = command.pane_id,
        .generation = command.pane_generation,
    };

    return handler.agents.acknowledge(key, command.now_ms);
}
