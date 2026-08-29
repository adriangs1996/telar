//! Bounded lifecycle state for model exchanges observed through the proxy.

const std = @import("std");
const evidence_mod = @import("evidence.zig");
const types = @import("types.zig");

const Evidence = evidence_mod.Evidence;
const ProxyExchange = types.ProxyExchange;
const ProxyObservation = types.ProxyObservation;
const ProxyPhase = types.ProxyPhase;

pub const ProxyState = struct {
    pub const ApplyResult = enum {
        ignored,
        activity_refreshed,
        evidence_replaced,
    };

    evidence: ?Evidence = null,
    active: [types.max_active_proxy_requests]?ProxyExchange = @splat(null),
    active_count: u16 = 0,

    /// Applies one lifecycle observation while rejecting activity and
    /// completion for exchanges that were never opened.
    ///
    /// ```zig
    /// switch (state.apply(observation)) {
    ///     .ignored => {},
    ///     .activity_refreshed, .evidence_replaced => publish(),
    /// }
    /// ```
    pub fn apply(state: *ProxyState, observation: ProxyObservation) ApplyResult {
        const tracked = state.track(observation.phase, observation.exchange);

        if (observation.requiresTrackedExchange() and !tracked) {
            return .ignored;
        }

        if (observation.isResponseActivity()) {
            if (state.evidence) |*evidence| {
                if (observation.hasProvider(evidence.provider) and evidence.isWorking()) {
                    if (observation.observed_at_ms - evidence.observed_at_ms < types.activity_refresh_ms) {
                        return .ignored;
                    }

                    evidence.observed_at_ms = observation.observed_at_ms;
                    evidence.expires_at_ms = observation.observed_at_ms + types.working_expiry_ms;
                    return .activity_refreshed;
                }
            }
        }

        state.replaceEvidence(&observation);
        return .evidence_replaced;
    }

    /// Removes proxy evidence and every tracked exchange.
    ///
    /// ```zig
    /// state.clear();
    /// ```
    pub fn clear(state: *ProxyState) void {
        state.evidence = null;
        state.active = @splat(null);
        state.active_count = 0;
    }

    /// Clears the complete proxy lifecycle when its evidence has expired.
    ///
    /// ```zig
    /// _ = state.clearExpired(now_ms);
    /// ```
    pub fn clearExpired(state: *ProxyState, now_ms: i64) bool {
        const evidence = state.evidence orelse return false;

        if (!evidence.isExpired(now_ms)) {
            return false;
        }

        state.clear();
        return true;
    }

    /// Returns a copy of the latest proxy evidence, if one exists.
    ///
    /// ```zig
    /// const evidence = state.currentEvidence();
    /// ```
    pub fn currentEvidence(state: *const ProxyState) ?Evidence {
        return state.evidence;
    }

    fn replaceEvidence(state: *ProxyState, observation: *const ProxyObservation) void {
        state.evidence = Evidence.fromProxy(observation);
    }

    fn track(state: *ProxyState, phase: ProxyPhase, exchange: ProxyExchange) bool {
        return switch (phase) {
            .request_started => state.start(exchange),
            .response_activity => state.contains(exchange),
            .response_finished, .request_failed => state.settle(exchange),
        };
    }

    fn start(state: *ProxyState, exchange: ProxyExchange) bool {
        var free: ?*?ProxyExchange = null;

        for (&state.active) |*slot| {
            if (slot.*) |active| {
                if (sameExchange(active, exchange)) {
                    return false;
                }
            } else if (free == null) {
                free = slot;
            }
        }

        const destination = free orelse return false;
        destination.* = exchange;
        state.active_count += 1;
        return true;
    }

    fn contains(state: *const ProxyState, exchange: ProxyExchange) bool {
        for (state.active) |active| {
            if (active != null and sameExchange(active.?, exchange)) {
                return true;
            }
        }

        return false;
    }

    fn settle(state: *ProxyState, exchange: ProxyExchange) bool {
        if (exchange.protocol == .h2 and exchange.stream_id == 0) {
            var removed = false;

            for (&state.active) |*slot| {
                const active = slot.* orelse continue;

                if (active.protocol != .h2 or active.connection_id != exchange.connection_id) {
                    continue;
                }

                slot.* = null;
                state.active_count -= 1;
                removed = true;
            }

            return removed;
        }

        for (&state.active) |*slot| {
            const active = slot.* orelse continue;

            if (!sameExchange(active, exchange)) {
                continue;
            }

            slot.* = null;
            state.active_count -= 1;
            return true;
        }

        return false;
    }
};

fn sameExchange(left: ProxyExchange, right: ProxyExchange) bool {
    return left.protocol == right.protocol and
        left.connection_id == right.connection_id and
        left.stream_id == right.stream_id;
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

test "proxy state HTTP2 sentinel settles only its connection streams" {
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
    try std.testing.expect(state.settle(connection));

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
