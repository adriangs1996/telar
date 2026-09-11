//! Periodic expiration coordination for runtime-owned agent projections.

const GenericAgentMaintenanceRuntimePort = @import("GenericAgentMaintenanceRuntimePort.zig").Type;
const AgentMaintenanceCapture = @import("AgentMaintenanceCapture.zig");
const GenericAgentMaintenanceCoordinator = @import("GenericAgentMaintenanceCoordinator.zig").Type;
const IdentityType = @import("../../../agent/Identity.zig");
const pane_module = @import("telar-core").pane;
const TrackerType = @import("../../../agent/Tracker.zig");
const ProxyExchangeType = @import("../../../agent/ProxyExchange.zig");
const std = @import("std");
const AgentStatusType = @import("telar-core").AgentStatus;

pub const Step = enum {
    rearm_tick,
    clock,
    pump_clients,
};

const test_port: GenericAgentMaintenanceRuntimePort(AgentMaintenanceCapture) = .{
    .rearm_tick = AgentMaintenanceCapture.rearmTick,
    .now_ms = AgentMaintenanceCapture.nowMs,
    .pump_clients = AgentMaintenanceCapture.pumpClients,
};

const TestCoordinator = GenericAgentMaintenanceCoordinator(AgentMaintenanceCapture, test_port);

fn testIdentity() !IdentityType {
    return .{
        .key = .{ .id = try pane_module(7), .generation = 11 },
        .process_id = 13,
        .session_id = .{17} ** 16,
    };
}

fn seedReadyAgent(agents: *TrackerType, identity: IdentityType, completed_at_ms: i64) !void {
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

fn testCoordinator(capture: *AgentMaintenanceCapture, agents: *TrackerType) TestCoordinator {
    capture.agents = agents;
    return TestCoordinator.init(capture, .{ .agents = agents });
}

fn expectSteps(capture: *const AgentMaintenanceCapture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "timer failure preserves projections and stops periodic maintenance" {
    var agents: TrackerType = .{};
    const identity = try testIdentity();
    try seedReadyAgent(&agents, identity, 100);
    var capture: AgentMaintenanceCapture = .{ .now = std.math.maxInt(i64), .identity = identity };
    var coordinator = testCoordinator(&capture, &agents);

    try coordinator.handle(error.TimerFailed);

    try expectSteps(&capture, &.{});
    try std.testing.expectEqual(AgentStatusType.done, agents.projectedStatus(identity.key).?);
}

test "rearm failure propagates before reading the clock or expiring evidence" {
    var agents: TrackerType = .{};
    const identity = try testIdentity();
    try seedReadyAgent(&agents, identity, 100);
    var capture: AgentMaintenanceCapture = .{
        .rearm_failure = true,
        .now = std.math.maxInt(i64),
        .identity = identity,
    };
    var coordinator = testCoordinator(&capture, &agents);

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle({}));

    try expectSteps(&capture, &.{.rearm_tick});
    try std.testing.expectEqual(AgentStatusType.done, agents.projectedStatus(identity.key).?);
}

test "successful maintenance pumps an unchanged projection" {
    var agents: TrackerType = .{};
    const identity = try testIdentity();
    try seedReadyAgent(&agents, identity, 100);
    var capture: AgentMaintenanceCapture = .{ .now = 101, .identity = identity };
    var coordinator = testCoordinator(&capture, &agents);

    try coordinator.handle({});

    try expectSteps(&capture, &.{ .rearm_tick, .clock, .pump_clients });
    try std.testing.expect(capture.pump_called);
    try std.testing.expectEqual(AgentStatusType.done, capture.pump_saw_status.?);
}

test "expired evidence is removed before clients are pumped" {
    var agents: TrackerType = .{};
    const identity = try testIdentity();
    try seedReadyAgent(&agents, identity, 100);
    var capture: AgentMaintenanceCapture = .{ .now = std.math.maxInt(i64), .identity = identity };
    var coordinator = testCoordinator(&capture, &agents);

    try coordinator.handle({});

    try expectSteps(&capture, &.{ .rearm_tick, .clock, .pump_clients });
    try std.testing.expect(capture.pump_called);
    try std.testing.expect(capture.pump_saw_status == null);
    try std.testing.expect(agents.projectedStatus(identity.key) == null);
}
