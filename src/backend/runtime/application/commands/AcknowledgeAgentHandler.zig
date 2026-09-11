const AcknowledgeAgentHandler = @This();
const source_namespace = @import("acknowledge_agent.zig");
const AcknowledgeAgent = @import("AcknowledgeAgent.zig");
const pane_mod = @import("../../../pane/root.zig");
agents: *source_namespace.Tracker,

/// Resolves the exact pane generation and lets the tracker turn an unseen
/// completion back into `ready`. The tracker revision advances only when
/// the projection changes.
///
/// ```zig
/// const result = handler.execute(.{ .pane_id = pane_id, .pane_generation = 3, .now_ms = now_ms });
/// ```
pub fn execute(handler: *AcknowledgeAgentHandler, command: AcknowledgeAgent) source_namespace.AcknowledgeAgentResult {
    const key: pane_mod.PaneKey = .{
        .id = command.pane_id,
        .generation = command.pane_generation,
    };

    return handler.agents.acknowledge(key, command.now_ms);
}
