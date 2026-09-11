//! Vertical tests for the agent acknowledgement request.

const GenericAcknowledgeAgentController = @import("../entrypoints/requests/GenericAcknowledgeAgentController.zig").Type;
const AcknowledgeAgentHandlerType = @import("../application/commands/AcknowledgeAgentHandler.zig");
const IdentityType = @import("../../agent/Identity.zig");
const pane_module = @import("telar-core").pane;
const TrackerType = @import("../../agent/Tracker.zig");
const ProxyExchangeType = @import("../../agent/ProxyExchange.zig");
const std = @import("std");
const AgentStatusType = @import("telar-core").AgentStatus;
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const AcknowledgeAgentType = @import("telar-core").AcknowledgeAgent;

const AcknowledgeController = GenericAcknowledgeAgentController(*AcknowledgeAgentHandlerType);

fn testIdentity() !IdentityType {
    return .{
        .key = .{ .id = try pane_module(7), .generation = 11 },
        .process_id = 13,
        .session_id = .{17} ** 16,
    };
}

fn completeTurn(agents: *TrackerType, identity: IdentityType, completed_at_ms: i64) !void {
    const exchange: ProxyExchangeType = .{
        .protocol = .h2,
        .connection_id = 19,
        .stream_id = 23,
    };
    try std.testing.expect(agents.observeProxy(.{
        .identity = identity,
        .dialect = .openai_responses,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = completed_at_ms - 1,
    }));
    try std.testing.expect(agents.observeProxy(.{
        .identity = identity,
        .dialect = .openai_responses,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = completed_at_ms,
    }));
}

test "acknowledgement crosses controller and handler and turns done into ready" {
    var agents: TrackerType = .{};
    const identity = try testIdentity();
    try completeTurn(&agents, identity, 1_000);
    try std.testing.expectEqual(AgentStatusType.done, agents.projectedStatus(identity.key).?);
    const revision = agents.revision;
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var handler: AcknowledgeAgentHandlerType = .{ .agents = &agents };
    var controller = AcknowledgeController.init(&metrics, &handler);

    controller.acknowledgeAgent(.{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation,
    }, 1_500);

    try std.testing.expectEqual(AgentStatusType.ready, agents.projectedStatus(identity.key).?);
    try std.testing.expect(agents.revision > revision);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "a repeated acknowledgement changes nothing and is not stale" {
    var agents: TrackerType = .{};
    const identity = try testIdentity();
    try completeTurn(&agents, identity, 1_000);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var handler: AcknowledgeAgentHandlerType = .{ .agents = &agents };
    var controller = AcknowledgeController.init(&metrics, &handler);
    const acknowledgement: AcknowledgeAgentType = .{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation,
    };

    controller.acknowledgeAgent(acknowledgement, 1_500);
    const revision = agents.revision;
    controller.acknowledgeAgent(acknowledgement, 1_600);

    try std.testing.expectEqual(revision, agents.revision);
    try std.testing.expectEqual(AgentStatusType.ready, agents.projectedStatus(identity.key).?);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "a stale generation is counted and leaves the agent done" {
    var agents: TrackerType = .{};
    const identity = try testIdentity();
    try completeTurn(&agents, identity, 1_000);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var handler: AcknowledgeAgentHandlerType = .{ .agents = &agents };
    var controller = AcknowledgeController.init(&metrics, &handler);

    controller.acknowledgeAgent(.{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation - 1,
    }, 1_500);

    try std.testing.expectEqual(AgentStatusType.done, agents.projectedStatus(identity.key).?);
    try std.testing.expectEqual(@as(u64, 1), metrics.stale_client_messages);
}

test "a new turn after acknowledgement reports done again" {
    var agents: TrackerType = .{};
    const identity = try testIdentity();
    try completeTurn(&agents, identity, 1_000);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var handler: AcknowledgeAgentHandlerType = .{ .agents = &agents };
    var controller = AcknowledgeController.init(&metrics, &handler);
    controller.acknowledgeAgent(.{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation,
    }, 1_500);

    try completeTurn(&agents, identity, 2_000);

    try std.testing.expectEqual(AgentStatusType.done, agents.projectedStatus(identity.key).?);
}
