const std = @import("std");
/// The subset of Claude Code hook input telar reads.
const ClaudeHookInput = @This();

hook_event_name: []const u8 = "",
session_id: []const u8 = "",
agent_id: ?[]const u8 = null,
transcript_path: []const u8 = "",
/// Present on `SessionStart` when the session already has a name.
session_title: []const u8 = "",
notification_type: []const u8 = "",
/// The text a `Notification` shows, such as the permission it asks for.
message: []const u8 = "",
/// Present on `Stop`: the final assistant message of the turn.
last_assistant_message: []const u8 = "",
tool_name: []const u8 = "",
tool_use_id: []const u8 = "",
tool_input: std.json.Value = .null,
cwd: []const u8 = "",
