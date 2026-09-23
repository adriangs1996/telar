const core = @import("telar-core");
const Evidence = @import("Evidence.zig");
const types = @import("types.zig");
const ProxyExchange = @import("ProxyExchange.zig");
const ProxyObservation = @import("ProxyObservation.zig");
const proxy_state = @import("proxy_state.zig");
const ProxyState = @This();

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
pub fn apply(self: *ProxyState, observation: ProxyObservation) ApplyResult {
    if (observation.phase == .request_started and self.isOlderThanEvidence(observation.observed_at_ms)) {
        return .ignored;
    }

    if (!self.track(observation.phase, observation.exchange)) {
        return .ignored;
    }

    if (observation.isResponseActivity()) {
        if (self.evidence) |*evidence| {
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

    if (!self.replaceEvidence(&observation, self.statusAfter(observation.phase))) {
        return .ignored;
    }

    return .evidence_replaced;
}

/// Removes proxy evidence and every tracked exchange.
///
/// ```zig
/// state.clear();
/// ```
pub fn clear(self: *ProxyState) void {
    self.evidence = null;
    self.active = @splat(null);
    self.active_count = 0;
}

/// Clears the complete proxy lifecycle when its evidence has expired.
///
/// ```zig
/// _ = state.clearExpired(now_ms);
/// ```
pub fn clearExpired(self: *ProxyState, now_ms: i64) bool {
    const evidence = self.evidence orelse return false;

    if (!evidence.isExpired(now_ms)) {
        return false;
    }

    self.clear();
    return true;
}

/// Reports whether the last response closed without completing the turn
/// while no exchange stays open: the model asked for a tool and the agent
/// has not called back yet, which is when a permission prompt is visible.
///
/// ```zig
/// if (state.awaitingToolResult()) reason = .permission;
/// ```
pub fn awaitingToolResult(self: *const ProxyState) bool {
    const evidence = self.evidence orelse return false;
    return evidence.status == .working and self.active_count == 0;
}

/// Returns a copy of the latest proxy evidence, if one exists.
///
/// ```zig
/// const evidence = state.currentEvidence();
/// ```
pub fn currentEvidence(self: *const ProxyState) ?Evidence {
    return self.evidence;
}

fn replaceEvidence(self: *ProxyState, observation: *const ProxyObservation, status: core.AgentStatus) bool {
    if (self.isOlderThanEvidence(observation.observed_at_ms)) {
        return false;
    }

    self.evidence = Evidence.fromProxy(observation, status);
    return true;
}

fn track(self: *ProxyState, phase: types.ProxyPhase, exchange: ProxyExchange) bool {
    return switch (phase) {
        .request_started => self.start(exchange),
        .response_activity => self.contains(exchange),
        .provider_turn_completed, .response_finished => self.settle(exchange),
        .request_failed => self.settleFailure(exchange),
    };
}

fn statusAfter(self: *const ProxyState, phase: types.ProxyPhase) core.AgentStatus {
    return switch (phase) {
        .request_started, .response_activity, .response_finished => .working,
        .provider_turn_completed => if (self.active_count == 0) .ready else .working,
        .request_failed => if (self.active_count == 0) .failed else .working,
    };
}

fn isOlderThanEvidence(self: *const ProxyState, observed_at_ms: i64) bool {
    const evidence = self.evidence orelse return false;
    return observed_at_ms < evidence.observed_at_ms;
}

pub fn start(self: *ProxyState, exchange: ProxyExchange) bool {
    var free: ?*?ProxyExchange = null;

    for (&self.active) |*slot| {
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
    self.active_count += 1;
    return true;
}

pub fn contains(self: *const ProxyState, exchange: ProxyExchange) bool {
    for (self.active) |active| {
        if (active != null and proxy_state.sameExchange(active.?, exchange)) {
            return true;
        }
    }

    return false;
}

pub fn settle(self: *ProxyState, exchange: ProxyExchange) bool {
    for (&self.active) |*slot| {
        const active = slot.* orelse continue;

        if (!proxy_state.sameExchange(active, exchange)) {
            continue;
        }

        slot.* = null;
        self.active_count -= 1;
        return true;
    }

    return false;
}

pub fn settleFailure(self: *ProxyState, exchange: ProxyExchange) bool {
    if (exchange.protocol == .h2 and exchange.stream_id == 0) {
        var removed = false;

        for (&self.active) |*slot| {
            const active = slot.* orelse continue;

            if (active.protocol != .h2 or active.connection_id != exchange.connection_id) {
                continue;
            }

            slot.* = null;
            self.active_count -= 1;
            removed = true;
        }

        return removed;
    }

    return self.settle(exchange);
}
