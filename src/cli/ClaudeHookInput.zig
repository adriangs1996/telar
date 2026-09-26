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
/// Present on `Stop` and `SubagentStop`: work the session left running,
/// such as background subagents and shells. Claude Code sends it without
/// documenting it, so an absent list means nothing is known to run.
background_tasks: []const BackgroundTask = &.{},
tool_name: []const u8 = "",
tool_use_id: []const u8 = "",
tool_input: std.json.Value = .null,
cwd: []const u8 = "",

const BackgroundTask = struct {
    type: []const u8 = "",
    status: []const u8 = "",
};

/// Counts the subagents still running after the turn. Background shells
/// are left out: a dev server outlives every turn and is not the agent
/// working.
///
/// ```zig
/// const running = input.runningSubagents();
/// ```
pub fn runningSubagents(self: *const ClaudeHookInput) usize {
    var running: usize = 0;
    for (self.background_tasks) |task| {
        if (std.mem.eql(u8, task.type, "subagent") and std.mem.eql(u8, task.status, "running")) {
            running += 1;
        }
    }

    return running;
}
