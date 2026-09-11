//! Time-bounded facts used to project one agent's visible state.

const IdentityType = @import("Identity.zig");
const pane_module = @import("telar-core").pane;
const ProxyExchangeType = @import("ProxyExchange.zig");
const types = @import("types.zig");
const AgentStatusType = @import("telar-core").AgentStatus;
const ProxyObservationType = @import("ProxyObservation.zig");
const Evidence = @import("Evidence.zig");
const std = @import("std");
const AgentProviderType = @import("telar-core").AgentProvider;
const AgentSourceType = @import("telar-core").AgentSource;

test "proxy evidence derives confidence and expiry from phase and aggregate status" {
    const identity: IdentityType = .{
        .key = .{ .id = try pane_module(7), .generation = 3 },
        .process_id = 42,
        .session_id = .{0xa5} ** 16,
    };
    const exchange: ProxyExchangeType = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const observed_at_ms: i64 = 100;
    const expectations = [_]struct {
        phase: types.ProxyPhase,
        status: AgentStatusType,
        confidence: u8,
        lifetime_ms: i64,
    }{
        .{ .phase = .request_started, .status = .working, .confidence = 95, .lifetime_ms = types.working_expiry_ms },
        .{ .phase = .response_activity, .status = .working, .confidence = 90, .lifetime_ms = types.working_expiry_ms },
        .{ .phase = .provider_turn_completed, .status = .ready, .confidence = 99, .lifetime_ms = types.settled_expiry_ms },
        .{ .phase = .provider_turn_completed, .status = .working, .confidence = 99, .lifetime_ms = types.working_expiry_ms },
        .{ .phase = .response_finished, .status = .working, .confidence = 95, .lifetime_ms = types.working_expiry_ms },
        .{ .phase = .request_failed, .status = .failed, .confidence = 98, .lifetime_ms = types.settled_expiry_ms },
    };

    for (expectations) |expectation| {
        const observation: ProxyObservationType = .{
            .identity = identity,
            .dialect = .anthropic_messages,
            .phase = expectation.phase,
            .exchange = exchange,
            .observed_at_ms = observed_at_ms,
        };
        const evidence = Evidence.fromProxy(&observation, expectation.status);

        try std.testing.expectEqual(AgentProviderType.claude, evidence.provider);
        try std.testing.expectEqual(expectation.status, evidence.status);
        try std.testing.expectEqual(AgentSourceType.proxy_tls, evidence.source);
        try std.testing.expectEqual(expectation.confidence, evidence.confidence);
        try std.testing.expectEqual(observed_at_ms, evidence.observed_at_ms);
        try std.testing.expectEqual(observed_at_ms + expectation.lifetime_ms, evidence.expires_at_ms);
    }
}
