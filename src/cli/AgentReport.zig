const core = @import("telar-core");
const AgentReport = @This();

/// The agent whose hook reports; `unknown` for a report the user sends.
provider: core.AgentProvider = .unknown,
state: core.AgentReportState,
blocked_reason: core.AgentBlockedReason = .none,
event: []const u8 = "",
session: []const u8 = "",
session_file: []const u8 = "",
session_file_kind: core.AgentSessionFileKind = .claude_transcript,
