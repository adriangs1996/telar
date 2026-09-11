//! Runtime anti-corruption layer from proxy events to agent observations.

const ObservationType = @import("../../../proxy/Observation.zig");
const Pane = @import("../../../pane/Pane.zig");
const ProxyObservationType = @import("../../../agent/ProxyObservation.zig");
const types = @import("../../../agent/types.zig");
const agent_identity = @import("../../application/coordinators/agent_identity.zig");
const GenericProxyObservationRuntimePort = @import("GenericProxyObservationRuntimePort.zig").Type;
const ProxyObservationCapture = @import("ProxyObservationCapture.zig");
const GenericProxyObservationAdapter = @import("GenericProxyObservationAdapter.zig").Type;
const middleware = @import("../../../proxy/middleware.zig");
const std = @import("std");
const enabled_module = @import("telar-core").enabled;
const Fixture = @import("Fixture.zig");
const AgentStatusType = @import("telar-core").AgentStatus;

pub fn translate(event: ObservationType, pane: *const Pane) ?ProxyObservationType {
    const phase: types.ProxyPhase = switch (event.phase) {
        .request_started => .request_started,
        .auxiliary_request_started => return null,
        .response_activity => .response_activity,
        .provider_turn_completed => .provider_turn_completed,
        .response_finished => .response_finished,
        .request_failed => .request_failed,
    };

    const protocol: types.ProxyProtocol = switch (event.protocol) {
        .http11 => .http11,
        .h2 => .h2,
        .upgraded => .upgraded,
    };

    return .{
        .identity = agent_identity.fromPane(pane),
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

pub const Step = enum {
    rearm_receive,
    schedule_description,
    pump_clients,
};

const test_port: GenericProxyObservationRuntimePort(ProxyObservationCapture) = .{
    .rearm_receive = ProxyObservationCapture.rearmReceive,
    .schedule_description = ProxyObservationCapture.scheduleDescription,
    .pump_clients = ProxyObservationCapture.pumpClients,
};

pub const TestAdapter = GenericProxyObservationAdapter(ProxyObservationCapture, test_port);

pub fn eventFor(pane: *const Pane, phase: middleware.Phase, protocol: middleware.Protocol) ObservationType {
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

fn expectSteps(capture: *const ProxyObservationCapture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

fn expectedProxyObservations() u64 {
    return if (enabled_module) 1 else 0;
}

test "every proxy protocol and inference phase translates without losing identity" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();

    for (std.enums.values(middleware.Phase)) |phase| {
        for (std.enums.values(middleware.Protocol)) |protocol| {
            const observation = translate(fixture.event(phase, protocol), fixture.support.pane);

            if (phase == .auxiliary_request_started) {
                try std.testing.expect(observation == null);
                continue;
            }

            const translated = observation.?;
            const expected_phase: types.ProxyPhase = switch (phase) {
                .request_started => .request_started,
                .auxiliary_request_started => unreachable,
                .response_activity => .response_activity,
                .provider_turn_completed => .provider_turn_completed,
                .response_finished => .response_finished,
                .request_failed => .request_failed,
            };
            const expected_protocol: types.ProxyProtocol = switch (protocol) {
                .http11 => .http11,
                .h2 => .h2,
                .upgraded => .upgraded,
            };

            try std.testing.expectEqualDeep(agent_identity.fromPane(fixture.support.pane), translated.identity);
            try std.testing.expectEqual(types.ApiDialect.openai_responses, translated.dialect);
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
    try std.testing.expectEqual(AgentStatusType.working, fixture.capture.status_at_description_schedule.?);
    try std.testing.expectEqual(AgentStatusType.working, fixture.support.agents.projectedStatus(fixture.support.pane.key()).?);
    try std.testing.expectEqual(expectedProxyObservations(), fixture.support.metrics.proxy_observations);
}

test "Claude provider completion projects ready for each HTTP protocol" {
    inline for (.{ middleware.Protocol.http11, .h2 }) |protocol| {
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

        try std.testing.expectEqual(AgentStatusType.working, fixture.support.agents.projectedStatus(fixture.support.pane.key()).?);
        fixture.capture.len = 0;

        var completed = fixture.event(.provider_turn_completed, protocol);
        completed.dialect = .anthropic_messages;
        completed.stream_id = stream_id;
        completed.status_code = 0;
        completed.observed_at_ms = 200;
        try adapter.handle(completed);

        try expectSteps(&fixture.capture, &.{ .rearm_receive, .schedule_description, .pump_clients });
        try std.testing.expectEqual(AgentStatusType.done, fixture.capture.status_at_description_schedule.?);
        try std.testing.expectEqual(AgentStatusType.done, fixture.support.agents.projectedStatus(fixture.support.pane.key()).?);
        fixture.capture.len = 0;

        var finished = fixture.event(.response_finished, protocol);
        finished.dialect = .anthropic_messages;
        finished.stream_id = stream_id;
        finished.status_code = 200;
        finished.observed_at_ms = 300;
        try adapter.handle(finished);

        try std.testing.expectEqual(AgentStatusType.done, fixture.support.agents.projectedStatus(fixture.support.pane.key()).?);
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
