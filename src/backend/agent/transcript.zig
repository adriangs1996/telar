//! The session name Claude Code writes to its transcript. `/rename` fires no
//! hook: the name only lands as a `custom-title` line in the JSONL file the
//! hooks point at. This is the pure scan over appended bytes; the runtime
//! owns the file I/O.

const max_agent_session_title_bytes_module = @import("telar-core").max_agent_session_title_bytes;
const Scan = @import("Scan.zig");
const std = @import("std");
const TitleLine = @import("TitleLine.zig");
const truncateSessionTitle_module = @import("telar-core").truncateSessionTitle;

/// Bytes one probe reads; a longer backlog continues on the next probe.
pub const max_scan_bytes = 64 * 1024;
/// A title line longer than this is skipped rather than parsed.
pub const max_line_bytes = 4096;
const title_prefix = "{\"type\":\"custom-title\"";

/// Finds the last `custom-title` line for `session` among the complete lines
/// in `bytes`. Other lines are skipped by prefix without parsing, so a
/// transcript full of large messages costs one scan for newlines.
///
/// ```zig
/// const result = scan(bytes, "0192...", &title_buffer);
/// ```
pub fn scan(bytes: []const u8, session: []const u8, buffer: *[max_agent_session_title_bytes_module]u8) Scan {
    var result: Scan = .{ .consumed = 0, .title = null };
    var rest = bytes;

    while (std.mem.indexOfScalar(u8, rest, '\n')) |newline| {
        const line = rest[0..newline];
        result.consumed += newline + 1;
        rest = rest[newline + 1 ..];
        if (!std.mem.startsWith(u8, line, title_prefix) or line.len > max_line_bytes) {
            continue;
        }

        var parse_buffer: [4 * max_line_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&parse_buffer);
        const parsed = std.json.parseFromSliceLeaky(TitleLine, fixed.allocator(), line, .{ .ignore_unknown_fields = true }) catch continue;
        if (!std.mem.eql(u8, parsed.sessionId, session)) {
            continue;
        }

        result.title = truncateSessionTitle_module(buffer, parsed.customTitle);
    }

    return result;
}

test "scan keeps the last name for the session and leaves a partial line" {
    var buffer: [max_agent_session_title_bytes_module]u8 = undefined;
    const bytes =
        "{\"type\":\"custom-title\",\"customTitle\":\"first\",\"sessionId\":\"abc\"}\n" ++
        "{\"type\":\"user\",\"message\":{\"content\":\"{\\\"type\\\":\\\"custom-title\\\"}\"}}\n" ++
        "{\"type\":\"custom-title\",\"customTitle\":\"other\",\"sessionId\":\"zzz\"}\n" ++
        "{\"type\":\"custom-title\",\"customTitle\":\"Fix \\\"proxy\\\"\",\"sessionId\":\"abc\"}\n" ++
        "{\"type\":\"custom-title\",\"customTitle\":\"partial";
    const result = scan(bytes, "abc", &buffer);

    try std.testing.expectEqualStrings("Fix \"proxy\"", result.title.?);
    try std.testing.expectEqual(bytes.len - "{\"type\":\"custom-title\",\"customTitle\":\"partial".len, result.consumed);
    try std.testing.expect(scan("{\"type\":\"custom-title\",\"customTitle\":\"x\",\"sessionId\":\"abc\"", "abc", &buffer).title == null);
    try std.testing.expect(scan("{\"type\":\"custom-title\",\"customTitle\":\"x\"\n", "abc", &buffer).title == null);
    try std.testing.expect(scan("{\"type\":\"custom-title\",not json\n", "abc", &buffer).title == null);
}

test "scan reports a cleared name as an empty title and bounds long names" {
    var buffer: [max_agent_session_title_bytes_module]u8 = undefined;
    const cleared = scan("{\"type\":\"custom-title\",\"customTitle\":\"\",\"sessionId\":\"abc\"}\n", "abc", &buffer);
    try std.testing.expectEqualStrings("", cleared.title.?);

    const long = "{\"type\":\"custom-title\",\"customTitle\":\"" ++ ("é" ** 60) ++ "\",\"sessionId\":\"abc\"}\n";
    const bounded = scan(long, "abc", &buffer);
    try std.testing.expectEqual(@as(usize, 96), bounded.title.?.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bounded.title.?));
}
