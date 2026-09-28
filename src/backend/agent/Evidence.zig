const core = @import("telar-core");
const ProcessObservation = @import("ProcessObservation.zig");
const std = @import("std");
const types = @import("types.zig");
const ScreenObservation = @import("ScreenObservation.zig");
const ReportObservation = @import("ReportObservation.zig");
const Evidence = @This();

provider: core.AgentProvider,
status: core.AgentStatus,
source: core.AgentSource,
confidence: u8,
observed_at_ms: i64,
observed_at_ns: ?i64 = null,
expires_at_ms: i64,

/// Converts one foreground-process observation into authoritative evidence.
///
/// ```zig
/// const evidence = Evidence.fromProcess(&observation);
/// ```
pub fn fromProcess(observation: *const ProcessObservation) Evidence {
    return .{
        .provider = observation.provider,
        .status = .ready,
        .source = .foreground_process,
        .confidence = 100,
        .observed_at_ms = observation.observed_at_ms,
        .expires_at_ms = std.math.maxInt(i64),
    };
}

/// Converts one accepted screen observation into expiring evidence using
/// the provider identity already resolved by the aggregate.
///
/// ```zig
/// const evidence = Evidence.fromScreen(.claude, &observation);
/// ```
pub fn fromScreen(provider: core.AgentProvider, observation: *const ScreenObservation) Evidence {
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
/// screen: active work and helpers still at work keep the long report
/// expiry, a settling report the short one, and settled states the
/// settled one.
///
/// ```zig
/// const evidence = Evidence.fromReport(.claude, &observation);
/// ```
pub fn fromReport(provider: core.AgentProvider, observation: *const ReportObservation) Evidence {
    std.debug.assert(observation.state != .exited and observation.state != .continuing);
    const status: core.AgentStatus = switch (observation.state) {
        .working, .settling, .waiting => .working,
        .blocked => .blocked,
        .ready, .idle, .released => .ready,
        .exited, .continuing => unreachable,
    };

    return .{
        .provider = provider,
        .status = status,
        .source = .lifecycle_report,
        .confidence = 100,
        .observed_at_ms = observation.observed_at_ms,
        .observed_at_ns = observation.observed_at_ns,
        .expires_at_ms = observation.observed_at_ms + switch (observation.state) {
            .working, .waiting => types.report_working_expiry_ms,
            .settling => types.working_expiry_ms,
            .blocked, .ready, .idle, .released => types.settled_expiry_ms,
            .exited, .continuing => unreachable,
        },
    };
}

/// Extends a working lifecycle report as if the agent had reported the
/// same work again at `now_ms`, once less than `report_renewal_margin_ms`
/// is left. Returns whether the expiry moved. The observation times stay,
/// so ordering against screen evidence still follows the report that
/// started the work.
///
/// ```zig
/// if (report.renewWork(observation.observed_at_ms)) {
///     publishProjection();
/// }
/// ```
pub fn renewWork(self: *Evidence, now_ms: i64) bool {
    std.debug.assert(self.source == .lifecycle_report and self.status == .working);
    if (self.expires_at_ms - now_ms > types.report_renewal_margin_ms) {
        return false;
    }

    self.expires_at_ms = now_ms + types.report_working_expiry_ms;
    return true;
}

/// Reports whether this evidence represents current model or tool work.
///
/// ```zig
/// if (evidence.isWorking()) {
///     keepAgentBusy();
/// }
/// ```
pub fn isWorking(self: *const Evidence) bool {
    return self.status == .working;
}

/// Reports whether this evidence is no longer valid at `now_ms`.
///
/// ```zig
/// if (evidence.isExpired(now_ms)) {
///     discardEvidence();
/// }
/// ```
pub fn isExpired(self: *const Evidence, now_ms: i64) bool {
    return self.expires_at_ms <= now_ms;
}
