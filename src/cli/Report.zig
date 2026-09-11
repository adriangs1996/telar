const AgentReportStateType = @import("telar-core").AgentReportState;
const AgentSessionFileKindType = @import("telar-core").AgentSessionFileKind;
const Report = @This();

state: AgentReportStateType,
session: []const u8 = "",
/// Where the agent records its session, when the hook knows it.
session_file: []const u8 = "",
session_file_kind: AgentSessionFileKindType = .claude_transcript,
