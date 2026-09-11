const AgentCommandPhaseType = @import("telar-core").AgentCommandPhase;
const CommandReport = @This();

phase: AgentCommandPhaseType,
provider: []const u8,
tool_call_id: []const u8,
command: []const u8,
cwd: []const u8,
session: []const u8,
exit_code: ?i32,
