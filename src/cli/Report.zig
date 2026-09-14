const AgentReportStateType = @import("telar-core").AgentReportState;
const AgentSessionFileKindType = @import("telar-core").AgentSessionFileKind;
const AgentBlockedReasonType = @import("telar-core").AgentBlockedReason;
const Report = @This();

state: AgentReportStateType,
/// Why the agent is blocked, when the event names it.
blocked_reason: AgentBlockedReasonType = .none,
/// One line naming the moment: the prompt text, the tool call or the
/// result summary. Borrowed from the caller's buffer.
event: []const u8 = "",
session: []const u8 = "",
/// Where the agent records its session, when the hook knows it.
session_file: []const u8 = "",
session_file_kind: AgentSessionFileKindType = .claude_transcript,
