const core = @import("telar-core");
const CommandReport = @This();

phase: core.AgentCommandPhase,
provider: []const u8,
tool_call_id: []const u8,
command: []const u8,
cwd: []const u8,
session: []const u8,
exit_code: ?i32,
