//! Runtime anti-corruption layer from proxy events to agent observations.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");
const proxy_mod = @import("../../../proxy/root.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;
const test_support = @import("../../tests/support.zig");

const diagnostics = core.diagnostics;
const Pane = pane_mod.Pane;
const PaneStore = pane_mod.PaneStore;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Resources = struct {
    panes: *PaneStore,
    agents: *agent_mod.Tracker,
    metrics: *RuntimeMetrics,
};

/// Defines proxy receive scheduling and downstream effects bound by the
/// runtime instance.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        rearm_receive: *const fn (*Context) anyerror!void,
        schedule_description: *const fn (*Context) void,
        pump_clients: *const fn (*Context) void,
    };
}

/// Creates a statically dispatched proxy-observation adapter.
///
/// ```zig
/// const ProxyObservationAdapter = Adapter(Context, port);
/// ```
pub fn Adapter(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds one runtime's pane, agent, and telemetry stores.
        ///
        /// ```zig
        /// var adapter = ProxyObservationAdapter.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Rearms successful proxy receives before validating their pane
        /// generation. Live inference events are translated into agent-domain
        /// evidence; receive failures and auxiliary traffic are discarded.
        ///
        /// ```zig
        /// try adapter.handle(receive_result);
        /// ```
        pub fn handle(adapter: *Self, result: anyerror!proxy_mod.Observation) !void {
            const event = result catch return;
            try port.rearm_receive(adapter.context);

            const pane = adapter.resources.panes.resolve(event.pane) orelse {
                adapter.resources.metrics.stale_pane_events += 1;
                return;
            };

            if (comptime diagnostics.enabled) {
                adapter.resources.metrics.proxy_observations +|= 1;
            }

            const observation = translate(event, pane) orelse return;
            _ = adapter.resources.agents.observeProxy(observation);
            port.schedule_description(adapter.context);
            port.pump_clients(adapter.context);
        }
    };
}

fn translate(event: proxy_mod.Observation, pane: *const Pane) ?agent_mod.ProxyObservation {
    const phase: agent_mod.ProxyPhase = switch (event.phase) {
        .request_started => .request_started,
        .auxiliary_request_started => return null,
        .response_activity => .response_activity,
        .provider_turn_completed => .provider_turn_completed,
        .response_finished => .response_finished,
        .request_failed => .request_failed,
    };

    const protocol: agent_mod.ProxyProtocol = switch (event.protocol) {
        .http11 => .http11,
        .h2 => .h2,
        .upgraded => .upgraded,
    };

    return .{
        .identity = agent_mod.Identity.fromPane(pane),
        .dialect = event.dialect,
        .phase = phase,
        .exchange = .{
            .protocol = protocol,
            .connection_id = event.connection_id,
            .stream_id = event.stream_id,
        },
        .observed_at_ms = event.observed_at_ms,
    };
}

const Step = enum {
    rearm_receive,
    schedule_description,
    pump_clients,
};

const Capture = struct {
    steps: [3]Step = undefined,
    len: usize = 0,
    rearm_failure: bool = false,
    agents: ?*const agent_mod.Tracker = null,
    pane: pane_mod.PaneKey = undefined,
    status_at_description_schedule: ?core.schema.AgentStatus = null,

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }

    fn rearmReceive(capture: *Capture) !void {
        capture.record(.rearm_receive);

        if (capture.rearm_failure) {
            return error.SchedulerUnavailable;
        }
    }

    fn scheduleDescription(capture: *Capture) void {
        capture.record(.schedule_description);
        const agents = capture.agents orelse return;
        capture.status_at_description_schedule = agents.projectedStatus(capture.pane);
    }

    fn pumpClients(capture: *Capture) void {
        capture.record(.pump_clients);
    }
};

const test_port: RuntimePort(Capture) = .{
    .rearm_receive = Capture.rearmReceive,
    .schedule_description = Capture.scheduleDescription,
    .pump_clients = Capture.pumpClients,
};

const TestAdapter = Adapter(Capture, test_port);

fn eventFor(pane: *const Pane, phase: proxy_mod.ObservationPhase, protocol: proxy_mod.ObservationProtocol) proxy_mod.Observation {
    return .{
        .pane = pane.key(),
        .dialect = .openai_responses,
        .phase = phase,
        .protocol = protocol,
        .connection_id = 17,
        .stream_id = 23,
        .status_code = 503,
        .observed_at_ms = 29,
    };
}

const Fixture = struct {
    support: test_support.PaneFixture = .{},
    panes: PaneStore = .{},
    capture: Capture = .{},

    fn init(fixture: *Fixture) !void {
        try fixture.support.init();
        errdefer fixture.support.deinit();
        try fixture.panes.insert(fixture.support.pane);
        fixture.capture.agents = &fixture.support.agents;
        fixture.capture.pane = fixture.support.pane.key();
    }

    fn deinit(fixture: *Fixture) void {
        fixture.support.deinit();
    }

    fn adapter(fixture: *Fixture) TestAdapter {
        return TestAdapter.init(&fixture.capture, .{
            .panes = &fixture.panes,
            .agents = &fixture.support.agents,
            .metrics = &fixture.support.metrics,
        });
    }

    fn event(fixture: *const Fixture, phase: proxy_mod.ObservationPhase, protocol: proxy_mod.ObservationProtocol) proxy_mod.Observation {
        return eventFor(fixture.support.pane, phase, protocol);
    }
};

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

fn expectedProxyObservations() u64 {
    return if (diagnostics.enabled) 1 else 0;
}

test "every proxy protocol and inference phase translates without losing identity" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();

    for (std.enums.values(proxy_mod.ObservationPhase)) |phase| {
        for (std.enums.values(proxy_mod.ObservationProtocol)) |protocol| {
            const observation = translate(fixture.event(phase, protocol), fixture.support.pane);

            if (phase == .auxiliary_request_started) {
                try std.testing.expect(observation == null);
                continue;
            }

            const translated = observation.?;
            const expected_phase: agent_mod.ProxyPhase = switch (phase) {
                .request_started => .request_started,
                .auxiliary_request_started => unreachable,
                .response_activity => .response_activity,
                .provider_turn_completed => .provider_turn_completed,
                .response_finished => .response_finished,
                .request_failed => .request_failed,
            };
            const expected_protocol: agent_mod.ProxyProtocol = switch (protocol) {
                .http11 => .http11,
                .h2 => .h2,
                .upgraded => .upgraded,
            };

            try std.testing.expectEqualDeep(agent_mod.Identity.fromPane(fixture.support.pane), translated.identity);
            try std.testing.expectEqual(agent_mod.ApiDialect.openai_responses, translated.dialect);
            try std.testing.expectEqual(expected_phase, translated.phase);
            try std.testing.expectEqual(expected_protocol, translated.exchange.protocol);
            try std.testing.expectEqual(@as(u64, 17), translated.exchange.connection_id);
            try std.testing.expectEqual(@as(u32, 23), translated.exchange.stream_id);
            try std.testing.expectEqual(@as(i64, 29), translated.observed_at_ms);
        }
    }
}

test "receive failure does not rearm or mutate runtime state" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var adapter = fixture.adapter();

    try adapter.handle(error.ReceiveFailed);

    try expectSteps(&fixture.capture, &.{});
    try std.testing.expect(fixture.support.agents.projectedStatus(fixture.support.pane.key()) == null);
    try std.testing.expectEqual(@as(u64, 0), fixture.support.metrics.proxy_observations);
}

test "rearm failure propagates before applying a received observation" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.capture.rearm_failure = true;
    var adapter = fixture.adapter();

    try std.testing.expectError(
        error.SchedulerUnavailable,
        adapter.handle(fixture.event(.request_started, .h2)),
    );

    try expectSteps(&fixture.capture, &.{.rearm_receive});
    try std.testing.expect(fixture.support.agents.projectedStatus(fixture.support.pane.key()) == null);
    try std.testing.expectEqual(@as(u64, 0), fixture.support.metrics.proxy_observations);
}

test "a stale pane generation is counted after the receive is rearmed" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var adapter = fixture.adapter();
    var event = fixture.event(.request_started, .http11);
    event.pane.generation += 1;

    try adapter.handle(event);

    try expectSteps(&fixture.capture, &.{.rearm_receive});
    try std.testing.expectEqual(@as(u64, 1), fixture.support.metrics.stale_pane_events);
    try std.testing.expectEqual(@as(u64, 0), fixture.support.metrics.proxy_observations);
    try std.testing.expect(fixture.support.agents.projectedStatus(fixture.support.pane.key()) == null);
}

test "auxiliary traffic is measured but cannot create an agent" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var adapter = fixture.adapter();

    try adapter.handle(fixture.event(.auxiliary_request_started, .h2));

    try expectSteps(&fixture.capture, &.{.rearm_receive});
    try std.testing.expectEqual(expectedProxyObservations(), fixture.support.metrics.proxy_observations);
    try std.testing.expect(fixture.support.agents.projectedStatus(fixture.support.pane.key()) == null);
}

test "an inference start updates the agent before scheduling downstream work" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var adapter = fixture.adapter();

    try adapter.handle(fixture.event(.request_started, .upgraded));

    try expectSteps(&fixture.capture, &.{ .rearm_receive, .schedule_description, .pump_clients });
    try std.testing.expectEqual(core.schema.AgentStatus.working, fixture.capture.status_at_description_schedule.?);
    try std.testing.expectEqual(core.schema.AgentStatus.working, fixture.support.agents.projectedStatus(fixture.support.pane.key()).?);
    try std.testing.expectEqual(expectedProxyObservations(), fixture.support.metrics.proxy_observations);
}

test "Claude provider completion projects ready for each HTTP protocol" {
    inline for (.{ proxy_mod.ObservationProtocol.http11, .h2 }) |protocol| {
        var fixture: Fixture = .{};
        try fixture.init();
        defer fixture.deinit();
        var adapter = fixture.adapter();
        const stream_id: u32 = if (protocol == .http11) 0 else 23;

        var started = fixture.event(.request_started, protocol);
        started.dialect = .anthropic_messages;
        started.stream_id = stream_id;
        started.status_code = 0;
        started.observed_at_ms = 100;
        try adapter.handle(started);

        try std.testing.expectEqual(core.schema.AgentStatus.working, fixture.support.agents.projectedStatus(fixture.support.pane.key()).?);
        fixture.capture.len = 0;

        var completed = fixture.event(.provider_turn_completed, protocol);
        completed.dialect = .anthropic_messages;
        completed.stream_id = stream_id;
        completed.status_code = 0;
        completed.observed_at_ms = 200;
        try adapter.handle(completed);

        try expectSteps(&fixture.capture, &.{ .rearm_receive, .schedule_description, .pump_clients });
        try std.testing.expectEqual(core.schema.AgentStatus.done, fixture.capture.status_at_description_schedule.?);
        try std.testing.expectEqual(core.schema.AgentStatus.done, fixture.support.agents.projectedStatus(fixture.support.pane.key()).?);
        fixture.capture.len = 0;

        var finished = fixture.event(.response_finished, protocol);
        finished.dialect = .anthropic_messages;
        finished.stream_id = stream_id;
        finished.status_code = 200;
        finished.observed_at_ms = 300;
        try adapter.handle(finished);

        try std.testing.expectEqual(core.schema.AgentStatus.done, fixture.support.agents.projectedStatus(fixture.support.pane.key()).?);
    }
}

test "an unmatched lifecycle event still runs the established downstream policy" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var adapter = fixture.adapter();

    try adapter.handle(fixture.event(.response_finished, .http11));

    try expectSteps(&fixture.capture, &.{ .rearm_receive, .schedule_description, .pump_clients });
    try std.testing.expect(fixture.support.agents.projectedStatus(fixture.support.pane.key()) == null);
    try std.testing.expectEqual(expectedProxyObservations(), fixture.support.metrics.proxy_observations);
}
