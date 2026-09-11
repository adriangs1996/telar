const EvidenceType = @import("Evidence.zig");
const types = @import("types.zig");
const ProxyExchangeType = @import("ProxyExchange.zig");
const ProxyObservationType = @import("ProxyObservation.zig");
const AgentStatusType = @import("telar-core").AgentStatus;
const proxy_state = @import("proxy_state.zig");
const ProxyState = @This();

pub const ApplyResult = enum {
    ignored,
    activity_refreshed,
    evidence_replaced,
};

evidence: ?EvidenceType = null,
active: [types.max_active_proxy_requests]?ProxyExchangeType = @splat(null),
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
pub fn apply(state: *ProxyState, observation: ProxyObservationType) ApplyResult {
    if (observation.phase == .request_started and state.isOlderThanEvidence(observation.observed_at_ms)) {
        return .ignored;
    }

    if (!state.track(observation.phase, observation.exchange)) {
        return .ignored;
    }

    if (observation.isResponseActivity()) {
        if (state.evidence) |*evidence| {
            if (observation.impliedProvider() == evidence.provider and evidence.isWorking()) {
                if (observation.observed_at_ms - evidence.observed_at_ms < types.activity_refresh_ms) {
                    return .ignored;
                }

                evidence.observed_at_ms = observation.observed_at_ms;
                evidence.expires_at_ms = observation.observed_at_ms + types.working_expiry_ms;
                return .activity_refreshed;
            }
        }
    }

    if (!state.replaceEvidence(&observation, state.statusAfter(observation.phase))) {
        return .ignored;
    }

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
pub fn currentEvidence(state: *const ProxyState) ?EvidenceType {
    return state.evidence;
}

fn replaceEvidence(state: *ProxyState, observation: *const ProxyObservationType, status: AgentStatusType) bool {
    if (state.isOlderThanEvidence(observation.observed_at_ms)) {
        return false;
    }

    state.evidence = EvidenceType.fromProxy(observation, status);
    return true;
}

fn track(state: *ProxyState, phase: types.ProxyPhase, exchange: ProxyExchangeType) bool {
    return switch (phase) {
        .request_started => state.start(exchange),
        .response_activity => state.contains(exchange),
        .provider_turn_completed, .response_finished => state.settle(exchange),
        .request_failed => state.settleFailure(exchange),
    };
}

fn statusAfter(state: *const ProxyState, phase: types.ProxyPhase) AgentStatusType {
    return switch (phase) {
        .request_started, .response_activity, .response_finished => .working,
        .provider_turn_completed => if (state.active_count == 0) .ready else .working,
        .request_failed => if (state.active_count == 0) .failed else .working,
    };
}

fn isOlderThanEvidence(state: *const ProxyState, observed_at_ms: i64) bool {
    const evidence = state.evidence orelse return false;
    return observed_at_ms < evidence.observed_at_ms;
}

pub fn start(state: *ProxyState, exchange: ProxyExchangeType) bool {
    var free: ?*?ProxyExchangeType = null;

    for (&state.active) |*slot| {
        if (slot.*) |active| {
            if (proxy_state.sameExchange(active, exchange)) {
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

pub fn contains(state: *const ProxyState, exchange: ProxyExchangeType) bool {
    for (state.active) |active| {
        if (active != null and proxy_state.sameExchange(active.?, exchange)) {
            return true;
        }
    }

    return false;
}

pub fn settle(state: *ProxyState, exchange: ProxyExchangeType) bool {
    for (&state.active) |*slot| {
        const active = slot.* orelse continue;

        if (!proxy_state.sameExchange(active, exchange)) {
            continue;
        }

        slot.* = null;
        state.active_count -= 1;
        return true;
    }

    return false;
}

pub fn settleFailure(state: *ProxyState, exchange: ProxyExchangeType) bool {
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

    return state.settle(exchange);
}
