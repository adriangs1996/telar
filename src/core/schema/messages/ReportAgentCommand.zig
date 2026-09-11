const id = @import("../id.zig");
const agent = @import("agent.zig");
/// One shell command observed by an official agent hook. Start and finish
/// reports share a tool-call identifier so persistence can close the row
/// idempotently.
const ReportAgentCommand = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
phase: agent.AgentCommandPhase,
provider: []const u8,
tool_call_id: []const u8 = "",
command: []const u8,
cwd: []const u8 = "",
session: []const u8 = "",
exit_code: ?i32 = null,
