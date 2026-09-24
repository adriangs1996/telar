//! A proxy observation of a model exchange becomes agent evidence for the
//! pane whose credential made the request.
const agent_status = @import("agent_status.zig");

const core = @import("telar-core");
const Observation = @import("../proxy/Observation.zig");
const Pane = @import("../pane/Pane.zig");
const ProxyObservation = @import("../agent/ProxyObservation.zig");
const RuntimeModel = @import("RuntimeModel.zig");
const Sources = @import("Sources.zig");
const types = @import("../agent/types.zig");
const agent_description = @import("agent_description.zig");
const agent_identity = @import("agent_identity.zig");
const middleware = @import("../proxy/middleware.zig");
const std = @import("std");

/// Rearms the proxy receive and records one observation as agent evidence.
///
/// ```zig
/// try proxy_observation.receive(model, result);
/// ```
pub fn receive(model: *RuntimeModel, result: anyerror!Observation) !void {
    const event = result catch return;
    var sources = Sources.init(model.io, model.select);
    try sources.receiveProxyObservation(&model.resources.proxy);

    const pane = model.panes.resolve(event.pane) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };

    if (comptime core.enabled) {
        model.metrics.proxy_observations +|= 1;
    }

    const observation = translate(event, pane) orelse return;
    _ = agent_status.observeProxy(model, observation);
    agent_description.start(model);
}

fn translate(event: Observation, pane: *const Pane) ?ProxyObservation {
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

pub fn eventFor(pane: *const Pane, phase: middleware.Phase, protocol: middleware.Protocol) Observation {
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

const PaneFixture = @import("tests/PaneFixture.zig");

test "every proxy protocol and inference phase translates without losing identity" {
    var fixture: PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    for (std.enums.values(middleware.Phase)) |phase| {
        for (std.enums.values(middleware.Protocol)) |protocol| {
            const observation = translate(eventFor(fixture.pane, phase, protocol), fixture.pane);

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

            try std.testing.expectEqualDeep(agent_identity.fromPane(fixture.pane), translated.identity);
            try std.testing.expectEqual(types.ApiDialect.openai_responses, translated.dialect);
            try std.testing.expectEqual(expected_phase, translated.phase);
            try std.testing.expectEqual(expected_protocol, translated.exchange.protocol);
            try std.testing.expectEqual(@as(u64, 17), translated.exchange.connection_id);
            try std.testing.expectEqual(@as(u32, 23), translated.exchange.stream_id);
            try std.testing.expectEqual(@as(i64, 29), translated.observed_at_ms);
        }
    }
}
