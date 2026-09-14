const AgentReportStateType = @import("telar-core").AgentReportState;
const AgentSessionFileKindType = @import("telar-core").AgentSessionFileKind;
const AgentBlockedReasonType = @import("telar-core").AgentBlockedReason;
const AgentReport = @This();

state: AgentReportStateType,
blocked_reason: AgentBlockedReasonType = .none,
event: []const u8 = "",
session: []const u8 = "",
session_file: []const u8 = "",
session_file_kind: AgentSessionFileKindType = .claude_transcript,
