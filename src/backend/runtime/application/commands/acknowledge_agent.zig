//! Application command for marking one agent generation as seen.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");

pub const schema = core.schema;
pub const Tracker = agent_mod.Tracker;

pub const AcknowledgeAgent = @import("AcknowledgeAgent.zig");

pub const AcknowledgeAgentResult = agent_mod.AcknowledgeResult;

pub const AcknowledgeAgentHandler = @import("AcknowledgeAgentHandler.zig");

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
