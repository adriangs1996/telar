/// The subset of Codex hook input telar reads.
const CodexHookInput = @This();
const std = @import("std");
hook_event_name: []const u8 = "",
session_id: []const u8 = "",
agent_id: ?[]const u8 = null,
source: []const u8 = "",
tool_name: []const u8 = "",
tool_use_id: []const u8 = "",
tool_input: std.json.Value = .null,
cwd: []const u8 = "",
/// Not part of Codex's payload: the state database `run` resolves from
/// `CODEX_HOME`, where `/rename` lands as `threads.name`.
state_database: []const u8 = "",
