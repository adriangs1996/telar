const core = @import("telar-core");
const PaneKeyType = @import("../../../pane/PaneKey.zig");
const ReportAgentCommand = @This();

pane: PaneKeyType,
phase: core.AgentCommandPhase,
provider: []const u8,
tool_call_id: []const u8,
command: []const u8,
cwd: []const u8,
exit_code: ?i32,
now_ms: i64,
