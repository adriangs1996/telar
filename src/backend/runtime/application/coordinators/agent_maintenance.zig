//! Periodic expiration coordination for runtime-owned agent projections.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");

const schema = core.schema;

pub const Resources = struct {
    agents: *agent_mod.Tracker,
};

/// Defines timer rearming, clock access, and client delivery bound by the
/// runtime instance.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        rearm_tick: *const fn (*Context) anyerror!void,
        now_ms: *const fn (*Context) i64,
        pump_clients: *const fn (*Context) void,
    };
}

/// Creates a statically dispatched agent-maintenance coordinator.
///
/// ```zig
/// const AgentMaintenanceCoordinator = Coordinator(Context, port);
/// ```
pub fn Coordinator(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds periodic maintenance to one runtime-owned agent tracker.
        ///
        /// ```zig
        /// var coordinator = AgentMaintenanceCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Rearms a successful timer before expiring evidence against one wall
        /// clock reading. Timer failures preserve every projection; successful
        /// maintenance always gives clients a delivery opportunity.
        ///
        /// ```zig
        /// try coordinator.handle(tick_result);
        /// ```
        pub fn handle(coordinator: *Self, result: anyerror!void) !void {
            result catch return;
            try port.rearm_tick(coordinator.context);

            _ = coordinator.resources.agents.expire(port.now_ms(coordinator.context));
            port.pump_clients(coordinator.context);
        }
    };
}

const Step = enum {
    rearm_tick,
    clock,
    pump_clients,
};

const Capture = struct {
    steps: [3]Step = undefined,
    len: usize = 0,
    rearm_failure: bool = false,
    now: i64 = 0,
    agents: ?*const agent_mod.Tracker = null,
    identity: agent_mod.Identity = undefined,
    pump_saw_status: ?schema.AgentStatus = null,
    pump_called: bool = false,

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }

    fn rearmTick(capture: *Capture) !void {
        capture.record(.rearm_tick);

        if (capture.rearm_failure) {
            return error.SchedulerUnavailable;
        }
    }

    fn nowMs(capture: *Capture) i64 {
        capture.record(.clock);
        return capture.now;
    }

    fn pumpClients(capture: *Capture) void {
        capture.record(.pump_clients);
        capture.pump_called = true;

        const agents = capture.agents orelse return;
        capture.pump_saw_status = agents.projectedStatus(capture.identity.key);
    }
};

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
    try std.testing.expectEqual(schema.AgentStatus.ready, agents.projectedStatus(identity.key).?);
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
    try std.testing.expectEqual(schema.AgentStatus.ready, agents.projectedStatus(identity.key).?);
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
    try std.testing.expectEqual(schema.AgentStatus.ready, capture.pump_saw_status.?);
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
