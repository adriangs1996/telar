const std = @import("std");
const ToolHookInput = @This();

event: []const u8,
agent_id: ?[]const u8 = null,
tool_name: []const u8,
tool_call_id: []const u8,
tool_input: std.json.Value,
cwd: []const u8,
session: []const u8,
exit_code: ?i32,
