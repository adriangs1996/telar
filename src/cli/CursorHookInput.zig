const std = @import("std");
/// The subset of Cursor Agent hook input telar reads. Cursor names its
/// events in camelCase and carries the chat id as `conversation_id`.
const CursorHookInput = @This();

hook_event_name: []const u8 = "",
conversation_id: []const u8 = "",
/// The workspace roots the agent opened; the first one usually names the
/// directory its chat metadata is filed under.
workspace_roots: []const []const u8 = &.{},
tool_name: []const u8 = "",
tool_use_id: []const u8 = "",
tool_input: std.json.Value = .null,
/// Present on `postToolUse`: the tool's result as a JSON document inside a
/// string, `{"output":"…","exitCode":0}` for `Shell`.
tool_output: []const u8 = "",
cwd: []const u8 = "",
/// Not part of Cursor's payload: the chat's `meta.json`, which `run`
/// locates when a turn starts, where `/rename` lands as `title`.
chat_meta: []const u8 = "",

const ShellOutput = struct {
    exitCode: ?i32 = null,
};

/// Scratch for the exit code; skipped fields allocate nothing.
const max_output_parse_bytes = 256;

/// The Claude Code event name of a tool event, so the shared command and
/// review mappings read Cursor's tool calls too. A failed tool still ends
/// its call. Other events have none.
///
/// ```zig
/// const event = input.toolEvent() orelse return;
/// ```
pub fn toolEvent(self: *const CursorHookInput) ?[]const u8 {
    if (std.mem.eql(u8, self.hook_event_name, "preToolUse")) {
        return "PreToolUse";
    }

    if (std.mem.eql(u8, self.hook_event_name, "postToolUse") or std.mem.eql(u8, self.hook_event_name, "postToolUseFailure")) {
        return "PostToolUse";
    }

    return null;
}

/// The exit code a finished `Shell` call reports inside `tool_output`;
/// null for other tools, failures and unreadable output.
///
/// ```zig
/// const exit_code = input.shellExitCode();
/// ```
pub fn shellExitCode(self: *const CursorHookInput) ?i32 {
    if (!std.mem.eql(u8, self.hook_event_name, "postToolUse") or !std.mem.eql(u8, self.tool_name, "Shell")) {
        return null;
    }

    var parse_buffer: [max_output_parse_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&parse_buffer);
    const parsed = std.json.parseFromSliceLeaky(ShellOutput, fixed.allocator(), self.tool_output, .{ .ignore_unknown_fields = true }) catch return null;
    return parsed.exitCode;
}

/// The workspace the chat was most likely started in; empty when Cursor
/// reported none.
///
/// ```zig
/// const workspace = input.workspace();
/// ```
pub fn workspace(self: *const CursorHookInput) []const u8 {
    if (self.workspace_roots.len == 0) {
        return "";
    }

    return self.workspace_roots[0];
}

/// Where a tool ran: Cursor leaves `cwd` empty for commands in the
/// workspace, so the workspace stands in for it.
///
/// ```zig
/// const cwd = input.shellDirectory();
/// ```
pub fn shellDirectory(self: *const CursorHookInput) []const u8 {
    if (self.cwd.len != 0) {
        return self.cwd;
    }

    return self.workspace();
}

test "tool events take Claude Code's names and a failure ends the call" {
    try std.testing.expectEqualStrings("PreToolUse", (CursorHookInput{ .hook_event_name = "preToolUse" }).toolEvent().?);
    try std.testing.expectEqualStrings("PostToolUse", (CursorHookInput{ .hook_event_name = "postToolUse" }).toolEvent().?);
    try std.testing.expectEqualStrings("PostToolUse", (CursorHookInput{ .hook_event_name = "postToolUseFailure" }).toolEvent().?);
    try std.testing.expect((CursorHookInput{ .hook_event_name = "stop" }).toolEvent() == null);
}

test "a finished Shell call reports the exit code Cursor nests in its output" {
    const finished: CursorHookInput = .{
        .hook_event_name = "postToolUse",
        .tool_name = "Shell",
        .tool_output = "{\"output\":\"made\\n\",\"exitCode\":0}",
    };
    try std.testing.expectEqual(@as(?i32, 0), finished.shellExitCode());

    const failed: CursorHookInput = .{
        .hook_event_name = "postToolUse",
        .tool_name = "Shell",
        .tool_output = "{\"output\":\"\",\"exitCode\":2}",
    };
    try std.testing.expectEqual(@as(?i32, 2), failed.shellExitCode());

    const read: CursorHookInput = .{
        .hook_event_name = "postToolUse",
        .tool_name = "Read",
        .tool_output = "{\"exitCode\":0}",
    };
    try std.testing.expect(read.shellExitCode() == null);

    const garbled: CursorHookInput = .{
        .hook_event_name = "postToolUse",
        .tool_name = "Shell",
        .tool_output = "not json",
    };
    try std.testing.expect(garbled.shellExitCode() == null);
}
