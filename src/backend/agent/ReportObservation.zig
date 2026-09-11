const Identity = @import("Identity.zig");
const AgentReportStateType = @import("telar-core").AgentReportState;
const SessionReference = @import("SessionReference.zig");
const SessionFile = @import("SessionFile.zig");
const ReportObservation = @This();

identity: Identity,
state: AgentReportStateType,
observed_at_ms: i64,
/// Monotonic runtime-ingress time, used to order same-millisecond frames.
observed_at_ns: ?i64 = null,
session: ?SessionReference = null,
/// Present when the hook knows where the agent records its session.
session_file: SessionFile = .{},
