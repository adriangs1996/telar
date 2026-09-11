/// One shell command observed by an official agent hook. Start and finish
/// reports share a tool-call identifier so persistence can close the row
/// idempotently.
const ReportAgentCommand = @This();
const source_namespace = @import("agent.zig");
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
pane_generation: u64,
phase: source_namespace.AgentCommandPhase,
provider: []const u8,
tool_call_id: []const u8 = "",
command: []const u8,
cwd: []const u8 = "",
session: []const u8 = "",
exit_code: ?i32 = null,
