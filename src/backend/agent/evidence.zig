const Evidence = @This();
const source_namespace = @import("evidence_support.zig");
const types = @import("types.zig");
const std = @import("std");
provider: source_namespace.schema.AgentProvider,
status: source_namespace.schema.AgentStatus,
source: source_namespace.schema.AgentSource,
confidence: u8,
observed_at_ms: i64,
observed_at_ns: ?i64 = null,
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

/// Converts one accepted proxy observation and the aggregate status after
/// that transition into expiring evidence.
///
/// ```zig
/// const evidence = Evidence.fromProxy(&observation, .working);
/// ```
pub fn fromProxy(observation: *const types.ProxyObservation, status: source_namespace.schema.AgentStatus) Evidence {
    std.debug.assert(status == .working or status == .ready or status == .failed);

    return .{
        .provider = observation.impliedProvider(),
        .status = status,
        .source = .proxy_tls,
        .confidence = switch (observation.phase) {
            .request_started, .response_finished => 95,
            .response_activity => 90,
            .provider_turn_completed => 99,
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
pub fn fromScreen(provider: source_namespace.schema.AgentProvider, observation: *const types.ScreenObservation) Evidence {
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
        .observed_at_ns = observation.observed_at_ns,
        .expires_at_ms = observation.observed_at_ms + switch (observation.signal.status) {
            .working => types.working_expiry_ms,
            .blocked, .ready => types.settled_expiry_ms,
        },
    };
}

/// Converts one official lifecycle report into the highest-ranked
/// evidence. Reports expire so a silent hook hands control back to the
/// proxy and screen.
///
/// ```zig
/// const evidence = Evidence.fromReport(.claude, &observation);
/// ```
pub fn fromReport(provider: source_namespace.schema.AgentProvider, observation: *const types.ReportObservation) Evidence {
    std.debug.assert(observation.state != .exited);
    const status: source_namespace.schema.AgentStatus = switch (observation.state) {
        .working, .settling => .working,
        .blocked => .blocked,
        .ready => .ready,
        .exited => unreachable,
    };

    return .{
        .provider = provider,
        .status = status,
        .source = .lifecycle_report,
        .confidence = 100,
        .observed_at_ms = observation.observed_at_ms,
        .observed_at_ns = observation.observed_at_ns,
        .expires_at_ms = observation.observed_at_ms + if (status == .working)
            types.working_expiry_ms
        else
            types.settled_expiry_ms,
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
