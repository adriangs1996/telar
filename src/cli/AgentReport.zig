const AgentReportStateType = @import("telar-core").AgentReportState;
const AgentSessionFileKindType = @import("telar-core").AgentSessionFileKind;
const AgentReport = @This();

state: AgentReportStateType,
session: []const u8 = "",
session_file: []const u8 = "",
session_file_kind: AgentSessionFileKindType = .claude_transcript,
