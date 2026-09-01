//! Vertical tests for the agent acknowledgement request.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const acknowledge_agent_commands = @import("../application/commands/acknowledge_agent.zig");
const acknowledge_agent_controller = @import("../entrypoints/requests/acknowledge_agent.zig");
const telemetry_mod = @import("../observability/root.zig").telemetry;

const schema = core.schema;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;
const AcknowledgeController = acknowledge_agent_controller.Controller(*acknowledge_agent_commands.AcknowledgeAgentHandler);

fn testIdentity() !agent_mod.Identity {
    return .{
        .key = .{ .id = try schema.id.pane(7), .generation = 11 },
        .process_id = 13,
        .session_id = .{17} ** 16,
    };
}

fn completeTurn(agents: *agent_mod.Tracker, identity: agent_mod.Identity, completed_at_ms: i64) !void {
    const exchange: agent_mod.ProxyExchange = .{
        .protocol = .h2,
        .connection_id = 19,
        .stream_id = 23,
    };
    try std.testing.expect(agents.observeProxy(.{
        .identity = identity,
        .provider = .codex,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = completed_at_ms - 1,
    }));
    try std.testing.expect(agents.observeProxy(.{
        .identity = identity,
        .provider = .codex,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = completed_at_ms,
    }));
}

test "acknowledgement crosses controller and handler and turns done into ready" {
    var agents: agent_mod.Tracker = .{};
    const identity = try testIdentity();
    try completeTurn(&agents, identity, 1_000);
    try std.testing.expectEqual(schema.AgentStatus.done, agents.projectedStatus(identity.key).?);
    const revision = agents.revision;
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var handler: acknowledge_agent_commands.AcknowledgeAgentHandler = .{ .agents = &agents };
    var controller = AcknowledgeController.init(&metrics, &handler);

    controller.acknowledgeAgent(.{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation,
    }, 1_500);

    try std.testing.expectEqual(schema.AgentStatus.ready, agents.projectedStatus(identity.key).?);
    try std.testing.expect(agents.revision > revision);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "a repeated acknowledgement changes nothing and is not stale" {
    var agents: agent_mod.Tracker = .{};
    const identity = try testIdentity();
    try completeTurn(&agents, identity, 1_000);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var handler: acknowledge_agent_commands.AcknowledgeAgentHandler = .{ .agents = &agents };
    var controller = AcknowledgeController.init(&metrics, &handler);
    const acknowledgement: schema.AcknowledgeAgent = .{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation,
    };

    controller.acknowledgeAgent(acknowledgement, 1_500);
    const revision = agents.revision;
    controller.acknowledgeAgent(acknowledgement, 1_600);

    try std.testing.expectEqual(revision, agents.revision);
    try std.testing.expectEqual(schema.AgentStatus.ready, agents.projectedStatus(identity.key).?);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "a stale generation is counted and leaves the agent done" {
    var agents: agent_mod.Tracker = .{};
    const identity = try testIdentity();
    try completeTurn(&agents, identity, 1_000);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var handler: acknowledge_agent_commands.AcknowledgeAgentHandler = .{ .agents = &agents };
    var controller = AcknowledgeController.init(&metrics, &handler);

    controller.acknowledgeAgent(.{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation - 1,
    }, 1_500);

    try std.testing.expectEqual(schema.AgentStatus.done, agents.projectedStatus(identity.key).?);
    try std.testing.expectEqual(@as(u64, 1), metrics.stale_client_messages);
}

test "a new turn after acknowledgement reports done again" {
    var agents: agent_mod.Tracker = .{};
    const identity = try testIdentity();
    try completeTurn(&agents, identity, 1_000);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var handler: acknowledge_agent_commands.AcknowledgeAgentHandler = .{ .agents = &agents };
    var controller = AcknowledgeController.init(&metrics, &handler);
    controller.acknowledgeAgent(.{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation,
    }, 1_500);

    try completeTurn(&agents, identity, 2_000);

    try std.testing.expectEqual(schema.AgentStatus.done, agents.projectedStatus(identity.key).?);
}
