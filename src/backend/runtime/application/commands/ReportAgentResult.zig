const core = @import("telar-core");
const ReportAgentResult = @This();

outcome: enum { applied, unchanged, pane_not_found, invalid_session },
previous: ?core.AgentStatus = null,
current: ?core.AgentStatus = null,
session_recorded: bool = false,
