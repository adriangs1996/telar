//! Bounded lifecycle state for model exchanges observed through the proxy.

const ProxyExchange = @import("ProxyExchange.zig");
const types = @import("types.zig");
const ProxyObservation = @import("ProxyObservation.zig");
const ProxyState = @import("ProxyState.zig");
const AgentStatusType = @import("telar-core").AgentStatus;
const std = @import("std");
const AgentProviderType = @import("telar-core").AgentProvider;

pub fn sameExchange(left: ProxyExchange, right: ProxyExchange) bool {
    return left.protocol == right.protocol and
        left.connection_id == right.connection_id and
        left.stream_id == right.stream_id;
}

fn testObservation(phase: types.ProxyPhase, exchange: ProxyExchange, observed_at_ms: i64) ProxyObservation {
    return .{
        .identity = .{
            .key = .{ .id = .invalid, .generation = 1 },
            .process_id = 1,
            .session_id = .{0xa5} ** 16,
        },
        .dialect = .anthropic_messages,
        .phase = phase,
        .exchange = exchange,
        .observed_at_ms = observed_at_ms,
    };
}

fn expectProxyEvidence(state: *const ProxyState, status: AgentStatusType, observed_at_ms: i64) !void {
    try std.testing.expect(state.currentEvidence() != null);
    const evidence = state.currentEvidence().?;
    try std.testing.expectEqual(AgentProviderType.claude, evidence.provider);
    try std.testing.expectEqual(status, evidence.status);
    try std.testing.expectEqual(observed_at_ms, evidence.observed_at_ms);
}

test "provider turn completion settles the last exchange as ready" {
    var state: ProxyState = .{};
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expectEqual(
        ProxyState.ApplyResult.evidence_replaced,
        state.apply(testObservation(.request_started, exchange, 100)),
    );
    try expectProxyEvidence(&state, .working, 100);
    try std.testing.expectEqual(@as(u16, 1), state.active_count);

    try std.testing.expectEqual(
        ProxyState.ApplyResult.evidence_replaced,
        state.apply(testObservation(.provider_turn_completed, exchange, 200)),
    );
    try expectProxyEvidence(&state, .ready, 200);
    try std.testing.expectEqual(@as(u8, 99), state.currentEvidence().?.confidence);
    try std.testing.expectEqual(200 + types.settled_expiry_ms, state.currentEvidence().?.expires_at_ms);
    try std.testing.expectEqual(@as(u16, 0), state.active_count);
    try std.testing.expect(!state.contains(exchange));
}

test "provider turn completion closes an exact exchange for every proxy protocol" {
    const exchanges = [_]ProxyExchange{
        .{ .protocol = .http11, .connection_id = 7, .stream_id = 0 },
        .{ .protocol = .h2, .connection_id = 8, .stream_id = 1 },
        .{ .protocol = .upgraded, .connection_id = 9, .stream_id = 0 },
    };

    for (exchanges) |exchange| {
        var state: ProxyState = .{};
        _ = state.apply(testObservation(.request_started, exchange, 100));

        try std.testing.expectEqual(
            ProxyState.ApplyResult.evidence_replaced,
            state.apply(testObservation(.provider_turn_completed, exchange, 200)),
        );
        try expectProxyEvidence(&state, .ready, 200);
        try std.testing.expectEqual(@as(u16, 0), state.active_count);
        try std.testing.expect(!state.contains(exchange));
    }
}

test "an untracked provider turn completion is ignored" {
    var state: ProxyState = .{};
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expectEqual(
        ProxyState.ApplyResult.ignored,
        state.apply(testObservation(.provider_turn_completed, exchange, 100)),
    );
    try std.testing.expect(state.currentEvidence() == null);
    try std.testing.expectEqual(@as(u16, 0), state.active_count);
}

test "provider turn completion is idempotent" {
    var state: ProxyState = .{};
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    _ = state.apply(testObservation(.request_started, exchange, 100));
    _ = state.apply(testObservation(.provider_turn_completed, exchange, 200));
    const completed = state.currentEvidence().?;

    try std.testing.expectEqual(
        ProxyState.ApplyResult.ignored,
        state.apply(testObservation(.provider_turn_completed, exchange, 300)),
    );
    try std.testing.expectEqualDeep(completed, state.currentEvidence().?);
    try std.testing.expectEqual(@as(u16, 0), state.active_count);
}

test "transport events after provider turn completion cannot regress ready evidence" {
    var state: ProxyState = .{};
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    _ = state.apply(testObservation(.request_started, exchange, 100));
    _ = state.apply(testObservation(.provider_turn_completed, exchange, 200));

    try std.testing.expectEqual(
        ProxyState.ApplyResult.ignored,
        state.apply(testObservation(.response_activity, exchange, 250)),
    );
    try std.testing.expectEqual(
        ProxyState.ApplyResult.ignored,
        state.apply(testObservation(.response_finished, exchange, 300)),
    );
    try expectProxyEvidence(&state, .ready, 200);
    try std.testing.expectEqual(@as(u16, 0), state.active_count);
}

test "provider turn completion remains working while another exchange is active" {
    var state: ProxyState = .{};
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 3 };

    _ = state.apply(testObservation(.request_started, first, 100));
    _ = state.apply(testObservation(.request_started, second, 110));
    _ = state.apply(testObservation(.provider_turn_completed, first, 200));

    try expectProxyEvidence(&state, .working, 200);
    try std.testing.expectEqual(200 + types.working_expiry_ms, state.currentEvidence().?.expires_at_ms);
    try std.testing.expectEqual(@as(u16, 1), state.active_count);
    try std.testing.expect(!state.contains(first));
    try std.testing.expect(state.contains(second));

    _ = state.apply(testObservation(.provider_turn_completed, second, 300));
    try expectProxyEvidence(&state, .ready, 300);
    try std.testing.expectEqual(@as(u16, 0), state.active_count);
}

test "new model work supersedes ready evidence" {
    var state: ProxyState = .{};
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 3 };

    _ = state.apply(testObservation(.request_started, first, 100));
    _ = state.apply(testObservation(.provider_turn_completed, first, 200));
    _ = state.apply(testObservation(.request_started, second, 300));

    try expectProxyEvidence(&state, .working, 300);
    try std.testing.expectEqual(@as(u16, 1), state.active_count);
    try std.testing.expect(state.contains(second));
}

test "an older request start cannot supersede ready evidence" {
    var state: ProxyState = .{};
    const completed: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const stale: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 3 };

    _ = state.apply(testObservation(.request_started, completed, 100));
    _ = state.apply(testObservation(.provider_turn_completed, completed, 300));

    try std.testing.expectEqual(
        ProxyState.ApplyResult.ignored,
        state.apply(testObservation(.request_started, stale, 200)),
    );
    try expectProxyEvidence(&state, .ready, 300);
    try std.testing.expectEqual(@as(u16, 0), state.active_count);
    try std.testing.expect(!state.contains(stale));
}

test "a late completion settles only its older exchange" {
    var state: ProxyState = .{};
    const older: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const current: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 3 };

    _ = state.apply(testObservation(.request_started, older, 100));
    _ = state.apply(testObservation(.request_started, current, 300));

    try std.testing.expectEqual(
        ProxyState.ApplyResult.ignored,
        state.apply(testObservation(.provider_turn_completed, older, 200)),
    );
    try expectProxyEvidence(&state, .working, 300);
    try std.testing.expectEqual(@as(u16, 1), state.active_count);
    try std.testing.expect(!state.contains(older));
    try std.testing.expect(state.contains(current));

    _ = state.apply(testObservation(.provider_turn_completed, current, 400));
    try expectProxyEvidence(&state, .ready, 400);
}

test "model and transport completion require an exact HTTP2 stream" {
    var state: ProxyState = .{};
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 3 };
    const connection: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 0 };

    _ = state.apply(testObservation(.request_started, first, 100));
    _ = state.apply(testObservation(.request_started, second, 110));

    try std.testing.expectEqual(
        ProxyState.ApplyResult.ignored,
        state.apply(testObservation(.provider_turn_completed, connection, 200)),
    );
    try std.testing.expectEqual(
        ProxyState.ApplyResult.ignored,
        state.apply(testObservation(.response_finished, connection, 210)),
    );
    try std.testing.expectEqual(@as(u16, 2), state.active_count);
    try std.testing.expect(state.contains(first));
    try std.testing.expect(state.contains(second));
}

test "a partial request failure preserves working evidence" {
    var state: ProxyState = .{};
    const failed: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const active: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 3 };

    _ = state.apply(testObservation(.request_started, failed, 100));
    _ = state.apply(testObservation(.request_started, active, 110));
    _ = state.apply(testObservation(.request_failed, failed, 200));

    try expectProxyEvidence(&state, .working, 200);
    try std.testing.expectEqual(@as(u16, 1), state.active_count);
    try std.testing.expect(state.contains(active));

    _ = state.apply(testObservation(.request_failed, active, 300));
    try expectProxyEvidence(&state, .failed, 300);
    try std.testing.expectEqual(@as(u16, 0), state.active_count);
}

test "an HTTP2 connection failure preserves work on another connection" {
    var state: ProxyState = .{};
    const failed_first: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const failed_second: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 3 };
    const remaining: ProxyExchange = .{ .protocol = .h2, .connection_id = 8, .stream_id = 1 };
    const failed_connection: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 0 };

    _ = state.apply(testObservation(.request_started, failed_first, 100));
    _ = state.apply(testObservation(.request_started, failed_second, 110));
    _ = state.apply(testObservation(.request_started, remaining, 120));
    _ = state.apply(testObservation(.request_failed, failed_connection, 200));

    try expectProxyEvidence(&state, .working, 200);
    try std.testing.expectEqual(@as(u16, 1), state.active_count);
    try std.testing.expect(!state.contains(failed_first));
    try std.testing.expect(!state.contains(failed_second));
    try std.testing.expect(state.contains(remaining));
}

test "apply rejects duplicate and overflowing request starts" {
    var state: ProxyState = .{};
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expectEqual(
        ProxyState.ApplyResult.evidence_replaced,
        state.apply(testObservation(.request_started, first, 100)),
    );
    try std.testing.expectEqual(
        ProxyState.ApplyResult.ignored,
        state.apply(testObservation(.request_started, first, 200)),
    );
    try expectProxyEvidence(&state, .working, 100);

    for (1..types.max_active_proxy_requests) |index| {
        const exchange: ProxyExchange = .{
            .protocol = .h2,
            .connection_id = 7,
            .stream_id = @intCast(index * 2 + 1),
        };
        try std.testing.expectEqual(
            ProxyState.ApplyResult.evidence_replaced,
            state.apply(testObservation(.request_started, exchange, @intCast(200 + index))),
        );
    }

    const overflow: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 999 };
    try std.testing.expectEqual(
        ProxyState.ApplyResult.ignored,
        state.apply(testObservation(.request_started, overflow, 1_000)),
    );
    try std.testing.expectEqual(@as(u16, types.max_active_proxy_requests), state.active_count);
    try std.testing.expect(!state.contains(overflow));
}

test "proxy state starts an exchange" {
    var state: ProxyState = .{};
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(state.start(exchange));
    try std.testing.expect(state.contains(exchange));
    try std.testing.expectEqual(@as(u16, 1), state.active_count);
}

test "proxy state rejects a duplicate exchange without changing its count" {
    var state: ProxyState = .{};
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };

    try std.testing.expect(state.start(exchange));
    try std.testing.expect(!state.start(exchange));
    try std.testing.expect(state.contains(exchange));
    try std.testing.expectEqual(@as(u16, 1), state.active_count);
}

test "proxy state does not exceed its bounded exchange capacity" {
    var state: ProxyState = .{};

    for (0..types.max_active_proxy_requests) |index| {
        const exchange: ProxyExchange = .{
            .protocol = .h2,
            .connection_id = 7,
            .stream_id = @intCast(index + 1),
        };
        try std.testing.expect(state.start(exchange));
    }

    const overflow: ProxyExchange = .{
        .protocol = .h2,
        .connection_id = 7,
        .stream_id = @intCast(types.max_active_proxy_requests + 1),
    };
    try std.testing.expect(!state.start(overflow));
    try std.testing.expect(!state.contains(overflow));
    try std.testing.expectEqual(@as(u16, types.max_active_proxy_requests), state.active_count);
}

test "proxy state settles only the specified exchange" {
    var state: ProxyState = .{};
    const settled: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const remaining: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 3 };

    try std.testing.expect(state.start(settled));
    try std.testing.expect(state.start(remaining));
    try std.testing.expect(state.settle(settled));

    try std.testing.expect(!state.contains(settled));
    try std.testing.expect(state.contains(remaining));
    try std.testing.expectEqual(@as(u16, 1), state.active_count);
    try std.testing.expect(!state.settle(settled));
    try std.testing.expectEqual(@as(u16, 1), state.active_count);
}

test "proxy state HTTP2 failure sentinel settles only its connection streams" {
    var state: ProxyState = .{};
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 3 };
    const other_connection: ProxyExchange = .{ .protocol = .h2, .connection_id = 8, .stream_id = 1 };
    const other_protocol: ProxyExchange = .{ .protocol = .http11, .connection_id = 7, .stream_id = 0 };
    const connection: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 0 };

    try std.testing.expect(state.start(first));
    try std.testing.expect(state.start(second));
    try std.testing.expect(state.start(other_connection));
    try std.testing.expect(state.start(other_protocol));
    try std.testing.expect(state.settleFailure(connection));

    try std.testing.expect(!state.contains(first));
    try std.testing.expect(!state.contains(second));
    try std.testing.expect(state.contains(other_connection));
    try std.testing.expect(state.contains(other_protocol));
    try std.testing.expectEqual(@as(u16, 2), state.active_count);
}

test "proxy state clear removes evidence and every active exchange" {
    var state: ProxyState = .{};
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 7, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .http11, .connection_id = 8, .stream_id = 0 };

    state.evidence = .{
        .provider = .claude,
        .status = .working,
        .source = .proxy_tls,
        .confidence = 95,
        .observed_at_ms = 100,
        .expires_at_ms = 200,
    };
    try std.testing.expect(state.start(first));
    try std.testing.expect(state.start(second));

    state.clear();

    try std.testing.expect(state.evidence == null);
    try std.testing.expectEqual(@as(u16, 0), state.active_count);
    for (state.active) |exchange| {
        try std.testing.expect(exchange == null);
    }
}
