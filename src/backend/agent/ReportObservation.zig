const Identity = @import("Identity.zig");
const AgentReportStateType = @import("telar-core").AgentReportState;
const SessionReference = @import("SessionReference.zig");
const SessionFile = @import("SessionFile.zig");
const AgentBlockedReasonType = @import("telar-core").AgentBlockedReason;
const ReportObservation = @This();

identity: Identity,
state: AgentReportStateType,
/// Why the agent is blocked, when the hook names it; `none` otherwise.
blocked_reason: AgentBlockedReasonType = .none,
/// One line naming the reported moment; empty when the hook has none.
event: []const u8 = "",
observed_at_ms: i64,
/// Monotonic runtime-ingress time, used to order same-millisecond frames.
observed_at_ns: ?i64 = null,
session: ?SessionReference = null,
/// Present when the hook knows where the agent records its session.
session_file: SessionFile = .{},
