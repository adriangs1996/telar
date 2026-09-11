/// The payload the Telar extension for Pi sends. Pi has no hook files: the
/// extension installed by `telar integration install pi` runs
/// `telar hook pi` on Pi's own extension events.
const PiHookInput = @This();
const std = @import("std");
event: []const u8 = "",
session_id: []const u8 = "",
/// Whether Pi had no run in progress when the event fired.
idle: ?bool = null,
blocked: bool = false,
tool_name: []const u8 = "",
tool_call_id: []const u8 = "",
tool_input: std.json.Value = .null,
cwd: []const u8 = "",
exit_code: ?i32 = null,
/// The session name on `session_start` and `session_info_changed`.
/// Absent on `session_info_changed` means the name was cleared.
name: ?[]const u8 = null,
