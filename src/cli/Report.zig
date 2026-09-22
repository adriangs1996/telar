const core = @import("telar-core");
const Report = @This();

state: core.AgentReportState,
/// Why the agent is blocked, when the event names it.
blocked_reason: core.AgentBlockedReason = .none,
/// One line naming the moment: the prompt text, the tool call or the
/// result summary. Borrowed from the caller's buffer.
event: []const u8 = "",
session: []const u8 = "",
/// Where the agent records its session, when the hook knows it.
session_file: []const u8 = "",
session_file_kind: core.AgentSessionFileKind = .claude_transcript,
