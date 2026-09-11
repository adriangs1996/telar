const AgentCommandReport = @This();
const source_namespace = @import("control.zig");
phase: source_namespace.schema.AgentCommandPhase,
provider: []const u8,
tool_call_id: []const u8,
command: []const u8,
cwd: []const u8,
session: []const u8,
exit_code: ?i32,
