//! Application command for marking one agent generation as seen.

const Tracker = @import("../../../agent/Tracker.zig");
const AcknowledgeAgentHandler = @import("AcknowledgeAgentHandler.zig");
const pane_module = @import("telar-core").pane;
const std = @import("std");
const tracker_support = @import("../../../agent/tracker_support.zig");

test "AcknowledgeAgentHandler reports an unknown generation without touching the tracker" {
    var agents: Tracker = .{};
    var handler: AcknowledgeAgentHandler = .{ .agents = &agents };
    const revision = agents.revision;

    const result = handler.execute(.{
        .pane_id = try pane_module(7),
        .pane_generation = 1,
        .now_ms = 1_000,
    });

    try std.testing.expectEqual(tracker_support.AcknowledgeResult.unknown_agent, result);
    try std.testing.expectEqual(revision, agents.revision);
}
