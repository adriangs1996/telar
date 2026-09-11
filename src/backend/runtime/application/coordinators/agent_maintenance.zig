//! Periodic expiration coordination for runtime-owned agent projections.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");

pub const schema = core.schema;

pub const Resources = @import("AgentMaintenanceResources.zig");

pub const RuntimePort = @import("GenericAgentMaintenanceRuntimePort.zig").Type;

pub const Coordinator = @import("GenericAgentMaintenanceCoordinator.zig").Type;

pub const Step = enum {
    rearm_tick,
    clock,
    pump_clients,
};

const Capture = @import("AgentMaintenanceCapture.zig");

const test_port: RuntimePort(Capture) = .{
    .rearm_tick = Capture.rearmTick,
    .now_ms = Capture.nowMs,
    .pump_clients = Capture.pumpClients,
};

const TestCoordinator = Coordinator(Capture, test_port);

fn testIdentity() !agent_mod.Identity {
    return .{
        .key = .{ .id = try schema.id.pane(7), .generation = 11 },
        .process_id = 13,
        .session_id = .{17} ** 16,
    };
}

fn seedReadyAgent(agents: *agent_mod.Tracker, identity: agent_mod.Identity, completed_at_ms: i64) !void {
    const exchange: agent_mod.ProxyExchange = .{
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

fn testCoordinator(capture: *Capture, agents: *agent_mod.Tracker) TestCoordinator {
    capture.agents = agents;
    return TestCoordinator.init(capture, .{ .agents = agents });
}

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "timer failure preserves projections and stops periodic maintenance" {
    var agents: agent_mod.Tracker = .{};
    const identity = try testIdentity();
    try seedReadyAgent(&agents, identity, 100);
    var capture: Capture = .{ .now = std.math.maxInt(i64), .identity = identity };
    var coordinator = testCoordinator(&capture, &agents);

    try coordinator.handle(error.TimerFailed);

    try expectSteps(&capture, &.{});
    try std.testing.expectEqual(schema.AgentStatus.done, agents.projectedStatus(identity.key).?);
}

test "rearm failure propagates before reading the clock or expiring evidence" {
    var agents: agent_mod.Tracker = .{};
    const identity = try testIdentity();
    try seedReadyAgent(&agents, identity, 100);
    var capture: Capture = .{
        .rearm_failure = true,
        .now = std.math.maxInt(i64),
        .identity = identity,
    };
    var coordinator = testCoordinator(&capture, &agents);

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle({}));

    try expectSteps(&capture, &.{.rearm_tick});
    try std.testing.expectEqual(schema.AgentStatus.done, agents.projectedStatus(identity.key).?);
}

test "successful maintenance pumps an unchanged projection" {
    var agents: agent_mod.Tracker = .{};
    const identity = try testIdentity();
    try seedReadyAgent(&agents, identity, 100);
    var capture: Capture = .{ .now = 101, .identity = identity };
    var coordinator = testCoordinator(&capture, &agents);

    try coordinator.handle({});

    try expectSteps(&capture, &.{ .rearm_tick, .clock, .pump_clients });
    try std.testing.expect(capture.pump_called);
    try std.testing.expectEqual(schema.AgentStatus.done, capture.pump_saw_status.?);
}

test "expired evidence is removed before clients are pumped" {
    var agents: agent_mod.Tracker = .{};
    const identity = try testIdentity();
    try seedReadyAgent(&agents, identity, 100);
    var capture: Capture = .{ .now = std.math.maxInt(i64), .identity = identity };
    var coordinator = testCoordinator(&capture, &agents);

    try coordinator.handle({});

    try expectSteps(&capture, &.{ .rearm_tick, .clock, .pump_clients });
    try std.testing.expect(capture.pump_called);
    try std.testing.expect(capture.pump_saw_status == null);
    try std.testing.expect(agents.projectedStatus(identity.key) == null);
}
