const std = @import("std");
/// What `map` reads from one hook event.
const ProgressHookInput = @This();

event: []const u8,
agent_id: ?[]const u8 = null,
tool_name: []const u8 = "",
tool_input: std.json.Value = .null,
cwd: []const u8 = "",
/// Claude Code's `CwdChanged`: the directory the agent moved to. Its `cwd`
/// still names the one it left.
new_cwd: []const u8 = "",
/// The agent's final answer; read only on `Stop`.
last_assistant_message: []const u8 = "",
