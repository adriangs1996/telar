const core = @import("telar-core");
const std = @import("std");
const ToolHookInput = @import("ToolHookInput.zig");
const ReviewHookFiles = @This();

pub const capacity = 32;

paths: [capacity][]const u8 = undefined,
count: usize = 0,

/// Reads only the tool's declared paths, never shell commands or source syntax.
/// Example: `const files = try ReviewHookFiles.collect(.codex, input);`
pub fn collect(provider: core.AgentProvider, input: ToolHookInput) !ReviewHookFiles {
    var self: ReviewHookFiles = .{};
    if (input.agent_id != null and input.agent_id.?.len != 0) {
        return self;
    }

    if (input.tool_input != .object or input.tool_call_id.len == 0) {
        return self;
    }

    if (provider == .claude and (std.mem.eql(u8, input.tool_name, "Write") or std.mem.eql(u8, input.tool_name, "Edit"))) {
        const path = input.tool_input.object.get("file_path") orelse return self;
        if (path == .string) {
            try self.append(path.string);
        }

        return self;
    }

    if (provider != .codex or !std.mem.eql(u8, input.tool_name, "apply_patch")) {
        return self;
    }

    const command = input.tool_input.object.get("command") orelse return self;
    if (command != .string) {
        return self;
    }

    var lines = std.mem.splitScalar(u8, command.string, '\n');
    if (!std.mem.eql(u8, std.mem.trim(u8, lines.next().?, "\r"), "*** Begin Patch")) {
        return error.InvalidReviewPatch;
    }

    var finished = false;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "*** End Patch")) {
            finished = true;
            break;
        }

        for ([_][]const u8{ "*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: " }) |prefix| {
            if (std.mem.startsWith(u8, line, prefix)) {
                try self.append(line[prefix.len..]);
                break;
            }
        }
    }

    if (!finished) {
        return error.InvalidReviewPatch;
    }

    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, "\r").len != 0) {
            return error.InvalidReviewPatch;
        }
    }

    return self;
}

fn append(self: *ReviewHookFiles, path: []const u8) !void {
    if (path.len == 0 or path.len >= std.fs.max_path_bytes or !std.unicode.utf8ValidateSlice(path)) {
        return error.InvalidReviewPath;
    }

    for (path) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidReviewPath;
        }
    }

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            return error.InvalidReviewPath;
        }
    }

    for (self.paths[0..self.count]) |previous| {
        if (std.mem.eql(u8, path, previous)) {
            return;
        }
    }

    if (self.count == self.paths.len) {
        return error.TooManyReviewFiles;
    }

    self.paths[self.count] = path;
    self.count += 1;
}

test "review hook paths track patch moves without interpreting source or shell commands" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"command":"*** Begin Patch\n*** Update File: old.py\n*** Move to: new.py\n@@\n-old\n+new\n*** Add File: created.go\n+x\n*** Delete File: old.py\n*** End Patch\n"}
    , .{});
    defer parsed.deinit();
    const input: ToolHookInput = .{ .event = "PreToolUse", .tool_name = "apply_patch", .tool_call_id = "tool-1", .tool_input = parsed.value, .cwd = "/work", .session = "session", .exit_code = null };
    const files = try ReviewHookFiles.collect(.codex, input);
    try std.testing.expectEqual(@as(usize, 3), files.count);
    try std.testing.expectEqualStrings("old.py", files.paths[0]);
    try std.testing.expectEqualStrings("new.py", files.paths[1]);
    try std.testing.expectEqualStrings("created.go", files.paths[2]);
    var shell = input;
    shell.tool_name = "Bash";
    try std.testing.expectEqual(@as(usize, 0), (try ReviewHookFiles.collect(.codex, shell)).count);
    var subagent = input;
    subagent.agent_id = "child";
    try std.testing.expectEqual(@as(usize, 0), (try ReviewHookFiles.collect(.codex, subagent)).count);
}

test "review hook paths reject traversal and overflow without truncating the tool" {
    var files: ReviewHookFiles = .{};
    try std.testing.expectError(error.InvalidReviewPath, files.append("../outside"));
    try std.testing.expectError(error.InvalidReviewPath, files.append("bad\nname"));
    var names: [capacity][8]u8 = undefined;
    for (&names, 0..) |*name, index| {
        try files.append(try std.fmt.bufPrint(name, "file-{d}", .{index}));
    }

    try files.append("file-0");
    try std.testing.expectError(error.TooManyReviewFiles, files.append("overflow"));
}

test "review hook paths accept Claude file tools and reject unrelated or malformed input" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"file_path\":\"/work/src/main.go\"}", .{});
    defer parsed.deinit();
    var input: ToolHookInput = .{ .event = "PostToolUse", .tool_name = "Edit", .tool_call_id = "tool-1", .tool_input = parsed.value, .cwd = "/work", .session = "session", .exit_code = 0 };
    const edited = try ReviewHookFiles.collect(.claude, input);
    try std.testing.expectEqualStrings("/work/src/main.go", edited.paths[0]);
    input.tool_name = "Write";
    try std.testing.expectEqual(@as(usize, 1), (try ReviewHookFiles.collect(.claude, input)).count);
    input.tool_name = "Read";
    try std.testing.expectEqual(@as(usize, 0), (try ReviewHookFiles.collect(.claude, input)).count);
    input.tool_input = .null;
    input.tool_name = "Edit";
    try std.testing.expectEqual(@as(usize, 0), (try ReviewHookFiles.collect(.claude, input)).count);
}
