//! Time-bounded facts used to project one agent's visible state.

const std = @import("std");
const core = @import("telar-core");
const types = @import("types.zig");

const schema = core.schema;

pub const Evidence = struct {
    provider: schema.AgentProvider,
    status: schema.AgentStatus,
    source: schema.AgentSource,
    confidence: u8,
    observed_at_ms: i64,
    expires_at_ms: i64,

    /// Converts one foreground-process observation into authoritative evidence.
    ///
    /// ```zig
    /// const evidence = Evidence.fromProcess(&observation);
    /// ```
    pub fn fromProcess(observation: *const types.ProcessObservation) Evidence {
        return .{
            .provider = observation.provider,
            .status = .ready,
            .source = .foreground_process,
            .confidence = 100,
            .observed_at_ms = observation.observed_at_ms,
            .expires_at_ms = std.math.maxInt(i64),
        };
    }

    /// Converts one accepted proxy observation into expiring agent evidence.
    ///
    /// ```zig
    /// const evidence = Evidence.fromProxy(&observation);
    /// ```
    pub fn fromProxy(observation: *const types.ProxyObservation) Evidence {
        const status: schema.AgentStatus = switch (observation.phase) {
            .request_started, .response_activity, .response_finished => .working,
            .request_failed => .failed,
        };

        return .{
            .provider = observation.provider,
            .status = status,
            .source = .proxy_tls,
            .confidence = switch (observation.phase) {
                .request_started, .response_finished => 95,
                .response_activity => 90,
                .request_failed => 98,
            },
            .observed_at_ms = observation.observed_at_ms,
            .expires_at_ms = observation.observed_at_ms + if (status == .working)
                types.working_expiry_ms
            else
                types.settled_expiry_ms,
        };
    }

    /// Converts one accepted screen observation into expiring evidence using
    /// the provider identity already resolved by the aggregate.
    ///
    /// ```zig
    /// const evidence = Evidence.fromScreen(.claude, &observation);
    /// ```
    pub fn fromScreen(provider: schema.AgentProvider, observation: *const types.ScreenObservation) Evidence {
        return .{
            .provider = provider,
            .status = switch (observation.signal.status) {
                .working => .working,
                .blocked => .blocked,
                .ready => .ready,
            },
            .source = .screen,
            .confidence = observation.signal.confidence,
            .observed_at_ms = observation.observed_at_ms,
            .expires_at_ms = observation.observed_at_ms + switch (observation.signal.status) {
                .working => types.working_expiry_ms,
                .blocked, .ready => types.settled_expiry_ms,
            },
        };
    }

    /// Reports whether this evidence represents current model or tool work.
    ///
    /// ```zig
    /// if (evidence.isWorking()) {
    ///     keepAgentBusy();
    /// }
    /// ```
    pub fn isWorking(evidence: *const Evidence) bool {
        return evidence.status == .working;
    }

    /// Reports whether this evidence is no longer valid at `now_ms`.
    ///
    /// ```zig
    /// if (evidence.isExpired(now_ms)) {
    ///     discardEvidence();
    /// }
    /// ```
    pub fn isExpired(evidence: *const Evidence, now_ms: i64) bool {
        return evidence.expires_at_ms <= now_ms;
    }
};

test "proxy evidence derives status confidence and expiry from its phase" {
    const identity: types.Identity = .{
        .key = .{ .id = try schema.id.pane(7), .generation = 3 },
        .process_id = 42,
        .session_id = .{0xa5} ** 16,
    };
    const exchange: types.ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const observed_at_ms: i64 = 100;
    const expectations = [_]struct {
        phase: types.ProxyPhase,
        status: schema.AgentStatus,
        confidence: u8,
        lifetime_ms: i64,
    }{
        .{ .phase = .request_started, .status = .working, .confidence = 95, .lifetime_ms = types.working_expiry_ms },
        .{ .phase = .response_activity, .status = .working, .confidence = 90, .lifetime_ms = types.working_expiry_ms },
        .{ .phase = .response_finished, .status = .working, .confidence = 95, .lifetime_ms = types.working_expiry_ms },
        .{ .phase = .request_failed, .status = .failed, .confidence = 98, .lifetime_ms = types.settled_expiry_ms },
    };

    for (expectations) |expectation| {
        const observation: types.ProxyObservation = .{
            .identity = identity,
            .provider = .claude,
            .phase = expectation.phase,
            .exchange = exchange,
            .observed_at_ms = observed_at_ms,
        };
        const evidence = Evidence.fromProxy(&observation);

        try std.testing.expectEqual(schema.AgentProvider.claude, evidence.provider);
        try std.testing.expectEqual(expectation.status, evidence.status);
        try std.testing.expectEqual(schema.AgentSource.proxy_tls, evidence.source);
        try std.testing.expectEqual(expectation.confidence, evidence.confidence);
        try std.testing.expectEqual(observed_at_ms, evidence.observed_at_ms);
        try std.testing.expectEqual(observed_at_ms + expectation.lifetime_ms, evidence.expires_at_ms);
    }
}
