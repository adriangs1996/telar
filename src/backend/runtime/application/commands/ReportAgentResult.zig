const AgentStatusType = @import("telar-core").AgentStatus;
const ReportAgentResult = @This();

outcome: enum { applied, unchanged, pane_not_found, invalid_session },
previous: ?AgentStatusType = null,
current: ?AgentStatusType = null,
session_recorded: bool = false,
