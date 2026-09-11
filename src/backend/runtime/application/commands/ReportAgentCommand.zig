const ReportAgentCommand = @This();
const pane_mod = @import("../../../pane/root.zig");
const source_namespace = @import("report_agent_command.zig");
pane: pane_mod.PaneKey,
phase: source_namespace.schema.AgentCommandPhase,
provider: []const u8,
tool_call_id: []const u8,
command: []const u8,
cwd: []const u8,
exit_code: ?i32,
now_ms: i64,
