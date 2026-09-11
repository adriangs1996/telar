const ReportAgentResult = @This();
const source_namespace = @import("report_agent.zig");
outcome: enum { applied, unchanged, pane_not_found, invalid_session },
previous: ?source_namespace.schema.AgentStatus = null,
current: ?source_namespace.schema.AgentStatus = null,
session_recorded: bool = false,
