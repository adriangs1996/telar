//! Formats the one-line event a lifecycle report carries: the tool call
//! that started, the question the agent asked or the message a prompt
//! shows. Every result is one control-free UTF-8 line within the wire
//! bound, so the runtime accepts it as it is.

const std = @import("std");
const max_agent_last_event_bytes_module = @import("telar-core").max_agent_last_event_bytes;

pub const Buffer = [max_agent_last_event_bytes_module]u8;

/// The tool input keys worth showing next to the tool name, in the order
/// they are tried. Shell commands and paths come first because they name
/// what the person will be asked about.
const argument_keys = [_][]const u8{ "command", "cmd", "file_path", "path", "pattern", "url", "query", "prompt", "description" };

/// Copies the first control-free line of `text` into `buffer`, cut to the
/// wire bound on a UTF-8 boundary.
///
/// ```zig
/// const event = line(&buffer, "Claude needs your permission to use Bash\n");
/// ```
pub fn line(buffer: *Buffer, text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len and end < buffer.len and text[end] >= 0x20 and text[end] != 0x7f) {
        end += 1;
    }

    while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) {
        end -= 1;
    }

    if (!std.unicode.utf8ValidateSlice(text[0..end])) {
        return buffer[0..0];
    }

    @memcpy(buffer[0..end], text[0..end]);
    return buffer[0..end];
}

/// Formats `» <tool> <argument>` from a hook's tool name and input, where
/// the argument is the first known string field of the input. A tool
/// without a known argument shows its name alone; no tool name yields null.
///
/// ```zig
/// const event = toolCall(&buffer, "Edit", input) orelse return;
/// ```
pub fn toolCall(buffer: *Buffer, tool_name: []const u8, tool_input: std.json.Value) ?[]const u8 {
    if (tool_name.len == 0) {
        return null;
    }

    // Each piece is bounded on its own so a long shell command still shows
    // the tool name; `line` then cuts the whole on a UTF-8 boundary.
    var scratch: [2 * max_agent_last_event_bytes_module]u8 = undefined;
    var len: usize = 0;
    append(&scratch, &len, "» ");
    append(&scratch, &len, tool_name);
    if (firstArgument(tool_input)) |argument| {
        append(&scratch, &len, " ");
        append(&scratch, &len, argument);
    }

    return line(buffer, scratch[0..len]);
}

fn append(scratch: []u8, len: *usize, text: []const u8) void {
    const count = @min(text.len, scratch.len - len.*);
    @memcpy(scratch[len.*..][0..count], text[0..count]);
    len.* += count;
}

/// The first question `AskUserQuestion` carries, so the card shows what
/// the agent wants to know instead of the tool name.
///
/// ```zig
/// const event = question(&buffer, input) orelse toolCall(&buffer, name, input);
/// ```
pub fn question(buffer: *Buffer, tool_input: std.json.Value) ?[]const u8 {
    if (tool_input != .object) {
        return null;
    }

    const questions = tool_input.object.get("questions") orelse return null;
    if (questions != .array or questions.array.items.len == 0) {
        return null;
    }

    const first = questions.array.items[0];
    if (first != .object) {
        return null;
    }

    const text = first.object.get("question") orelse return null;
    if (text != .string or text.string.len == 0) {
        return null;
    }

    return line(buffer, text.string);
}

fn firstArgument(tool_input: std.json.Value) ?[]const u8 {
    if (tool_input != .object) {
        return null;
    }

    for (argument_keys) |key| {
        const value = tool_input.object.get(key) orelse continue;
        if (value == .string and value.string.len != 0) {
            return value.string;
        }
    }

    return null;
}

fn parse(text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
}

test "tool calls show the tool and its first known argument on one line" {
    var buffer: Buffer = undefined;
    const edit = try parse("{\"file_path\":\"src/client/bars/Output.zig\",\"old_string\":\"a\"}");
    defer edit.deinit();
    try std.testing.expectEqualStrings("» Edit src/client/bars/Output.zig", toolCall(&buffer, "Edit", edit.value).?);

    const bash = try parse("{\"command\":\"zig build test\\nzig build check\",\"description\":\"tests\"}");
    defer bash.deinit();
    try std.testing.expectEqualStrings("» Bash zig build test", toolCall(&buffer, "Bash", bash.value).?);

    const bare = try parse("{\"unknown\":1}");
    defer bare.deinit();
    try std.testing.expectEqualStrings("» TodoWrite", toolCall(&buffer, "TodoWrite", bare.value).?);
    try std.testing.expect(toolCall(&buffer, "", bare.value) == null);
    try std.testing.expectEqualStrings("» Read", toolCall(&buffer, "Read", .null).?);
}

test "event lines are cut to the wire bound on a UTF-8 boundary" {
    var buffer: Buffer = undefined;
    const long = "é" ** 60;
    const cut = line(&buffer, long);
    try std.testing.expectEqual(@as(usize, 96), cut.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expectEqualStrings("", line(&buffer, "\xff"));
    try std.testing.expectEqualStrings("first", line(&buffer, "first\r\nsecond"));

    const wide = try parse("{\"command\":\"" ++ "x" ** 200 ++ "\"}");
    defer wide.deinit();
    try std.testing.expectEqual(@as(usize, 96), toolCall(&buffer, "Bash", wide.value).?.len);
}

test "the first question of AskUserQuestion becomes the event" {
    var buffer: Buffer = undefined;
    const asked = try parse("{\"questions\":[{\"question\":\"Which database?\",\"options\":[]},{\"question\":\"Other\"}]}");
    defer asked.deinit();
    try std.testing.expectEqualStrings("Which database?", question(&buffer, asked.value).?);

    const empty = try parse("{\"questions\":[]}");
    defer empty.deinit();
    try std.testing.expect(question(&buffer, empty.value) == null);
    try std.testing.expect(question(&buffer, .null) == null);
}
