const core = @import("telar-core");
const AgentReport = @This();

state: core.AgentReportState,
blocked_reason: core.AgentBlockedReason = .none,
event: []const u8 = "",
session: []const u8 = "",
session_file: []const u8 = "",
session_file_kind: core.AgentSessionFileKind = .claude_transcript,
