//! Application command for marking one agent generation as seen.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");

const schema = core.schema;
const Tracker = agent_mod.Tracker;

pub const AcknowledgeAgent = struct {
    pane_id: schema.PaneId,
    pane_generation: u64,
    now_ms: i64,
};

pub const AcknowledgeAgentResult = agent_mod.AcknowledgeResult;

pub const AcknowledgeAgentHandler = struct {
    agents: *Tracker,

    /// Resolves the exact pane generation and lets the tracker turn an unseen
    /// completion back into `ready`. The tracker revision advances only when
    /// the projection changes.
    ///
    /// ```zig
    /// const result = handler.execute(.{ .pane_id = pane_id, .pane_generation = 3, .now_ms = now_ms });
    /// ```
    pub fn execute(handler: *AcknowledgeAgentHandler, command: AcknowledgeAgent) AcknowledgeAgentResult {
        const key: pane_mod.PaneKey = .{
            .id = command.pane_id,
            .generation = command.pane_generation,
        };

        return handler.agents.acknowledge(key, command.now_ms);
    }
};

test "AcknowledgeAgentHandler reports an unknown generation without touching the tracker" {
    var agents: Tracker = .{};
    var handler: AcknowledgeAgentHandler = .{ .agents = &agents };
    const revision = agents.revision;

    const result = handler.execute(.{
        .pane_id = try schema.id.pane(7),
        .pane_generation = 1,
        .now_ms = 1_000,
    });

    try std.testing.expectEqual(AcknowledgeAgentResult.unknown_agent, result);
    try std.testing.expectEqual(revision, agents.revision);
}
