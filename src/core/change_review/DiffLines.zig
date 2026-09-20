//! Allocation-free unified diff reader. Unknown or incomplete input stays literal.
const std = @import("std");
const Line = @import("DiffLine.zig");
const Lines = @This();

text: []const u8,
index: usize = 0,
old: ?u32 = null,
new: ?u32 = null,
old_left: u32 = 0,
new_left: u32 = 0,
git_file: bool = false,
old_path: []const u8 = "",

/// Keeps source slices intact while assigning numbers only from valid hunks.
/// Example: `while (lines.next()) |line| render(line);`
pub fn next(lines: *Lines) ?Line {
    while (lines.index < lines.text.len) {
        const start = lines.index;
        const end = start + (std.mem.indexOfAny(u8, lines.text[start..], "\r\n") orelse lines.text.len - start);
        lines.index = end;
        if (lines.index < lines.text.len and lines.text[lines.index] == '\r') {
            lines.index += 1;
        }

        if (lines.index < lines.text.len and lines.text[lines.index] == '\n') {
            lines.index += 1;
        }

        const source = lines.text[start..end];
        for ([_][]const u8{ "Updated ", "Added ", "Deleted ", "Moved " }) |prefix| {
            if (std.mem.startsWith(u8, source, prefix)) {
                lines.reset();
                return .{ .kind = .file, .text = source[prefix.len..], .operation = prefix[0 .. prefix.len - 1] };
            }
        }

        if (std.mem.startsWith(u8, source, "diff --git ")) {
            lines.reset();
            lines.git_file = true;
            const path = if (std.mem.indexOf(u8, source, " b/")) |at| source[at + 3 ..] else source[11..];
            return .{ .kind = .file, .text = path };
        }

        if (std.mem.startsWith(u8, source, "@@")) {
            lines.old = null;
            lines.new = null;
            lines.old_left = 0;
            lines.new_left = 0;
            var parts = std.mem.tokenizeScalar(u8, source, ' ');
            const marker = parts.next().?;
            const old_range = parts.next() orelse return .{ .kind = .metadata, .text = source };
            const new_range = parts.next() orelse return .{ .kind = .metadata, .text = source };
            const closing = parts.next() orelse return .{ .kind = .metadata, .text = source };
            const before = range(old_range, '-') orelse return .{ .kind = .metadata, .text = source };
            const after = range(new_range, '+') orelse return .{ .kind = .metadata, .text = source };
            if (!std.mem.eql(u8, marker, "@@") or !std.mem.eql(u8, closing, "@@")) {
                return .{ .kind = .metadata, .text = source };
            }

            lines.old = before[0];
            lines.new = after[0];
            lines.old_left = before[1];
            lines.new_left = after[1];
            return .{ .kind = .hunk, .text = source, .old = before[0], .new = after[0] };
        }

        const in_hunk = lines.old_left > 0 or lines.new_left > 0;
        if (!in_hunk and std.mem.startsWith(u8, source, "--- ") and (lines.git_file or std.mem.startsWith(u8, lines.text[lines.index..], "+++ "))) {
            lines.old_path = source[4..];
            continue;
        }

        if (!in_hunk and std.mem.startsWith(u8, source, "+++ ") and (lines.git_file or lines.old_path.len > 0)) {
            if (lines.git_file) {
                continue;
            }

            const path = if (std.mem.eql(u8, source[4..], "/dev/null")) lines.old_path else source[4..];
            return .{ .kind = .file, .text = if (std.mem.startsWith(u8, path, "a/") or std.mem.startsWith(u8, path, "b/")) path[2..] else path };
        }

        if (lines.git_file and std.mem.startsWith(u8, source, "index ")) {
            continue;
        }

        const kind: Line.Kind = if (source.len == 0) .metadata else switch (source[0]) {
            '+' => .added,
            '-' => .removed,
            ' ' => .context,
            else => .metadata,
        };
        var line: Line = .{ .kind = kind, .text = if (kind == .added or kind == .removed or kind == .context) source[1..] else source };
        if ((kind == .removed or kind == .context) and lines.old_left > 0) {
            line.old = lines.old;
            lines.old = lines.old.? +| 1;
            lines.old_left -= 1;
        }

        if ((kind == .added or kind == .context) and lines.new_left > 0) {
            line.new = lines.new;
            lines.new = lines.new.? +| 1;
            lines.new_left -= 1;
        }

        return line;
    }

    return null;
}

/// Counts the next file's changes without consuming the reader or counting headers.
/// Example: `const added_removed = lines.counts();`
pub fn counts(lines: Lines) [2]u32 {
    var copy = lines;
    var result: [2]u32 = .{ 0, 0 };
    while (copy.next()) |line| {
        switch (line.kind) {
            .file => break,
            .added => result[0] += 1,
            .removed => result[1] += 1,
            else => {},
        }
    }

    return result;
}

fn reset(lines: *Lines) void {
    lines.old = null;
    lines.new = null;
    lines.old_left = 0;
    lines.new_left = 0;
    lines.git_file = false;
    lines.old_path = "";
}

fn range(text: []const u8, prefix: u8) ?[2]u32 {
    if (text.len < 2 or text[0] != prefix) {
        return null;
    }

    const comma = std.mem.indexOfScalar(u8, text, ',') orelse text.len;
    const start = std.fmt.parseInt(u32, text[1..comma], 10) catch return null;
    const count = if (comma < text.len) std.fmt.parseInt(u32, text[comma + 1 ..], 10) catch return null else 1;
    if (count > 0 and (start == 0 or count - 1 > std.math.maxInt(u32) - start)) {
        return null;
    }

    return .{ start, count };
}

test "diff numbers follow hunks and count code starting with header markers" {
    var lines: Lines = .{ .text = "Updated src/main.zig\n@@ -9,2 +9,3 @@\n old\n--- code\n+++ code\n+new\n" };
    try std.testing.expectEqualStrings("src/main.zig", lines.next().?.text);
    try std.testing.expectEqualDeep([2]u32{ 2, 1 }, lines.counts());
    try std.testing.expectEqual(.hunk, lines.next().?.kind);
    const context = lines.next().?;
    try std.testing.expectEqual(@as(?u32, 9), context.old);
    try std.testing.expectEqual(@as(?u32, 9), context.new);
    const removed = lines.next().?;
    try std.testing.expectEqual(.removed, removed.kind);
    try std.testing.expectEqualStrings("-- code", removed.text);
    try std.testing.expectEqual(@as(?u32, 10), removed.old);
    try std.testing.expectEqual(@as(?u32, null), removed.new);
    try std.testing.expectEqual(@as(?u32, 10), lines.next().?.new);
    try std.testing.expectEqual(@as(?u32, 11), lines.next().?.new);
    try std.testing.expect(lines.next() == null);
}

test "diff numbering resets between files and malformed or truncated hunks remain literal" {
    var lines: Lines = .{ .text = "@@ -2 +4 @@\r\n-old\r\n+new\r\nAdded new.zig\n+hello\n@@ -999999999999 +1 @@\n+unknown\n@@ -0,0 +1,1 @@\n+first\n\\ No newline at end of file\n" };
    _ = lines.next();
    try std.testing.expectEqual(@as(?u32, 2), lines.next().?.old);
    try std.testing.expectEqual(@as(?u32, 4), lines.next().?.new);
    try std.testing.expectEqual(.file, lines.next().?.kind);
    try std.testing.expectEqual(@as(?u32, null), lines.next().?.new);
    try std.testing.expectEqual(.metadata, lines.next().?.kind);
    try std.testing.expectEqual(@as(?u32, null), lines.next().?.new);
    _ = lines.next();
    try std.testing.expectEqual(@as(?u32, 1), lines.next().?.new);
    try std.testing.expectEqual(.metadata, lines.next().?.kind);
}

test "git and plain unified headers produce one file title and exact statistics" {
    for ([_][]const u8{ "diff --git a/old.zig b/old.zig\nindex 123..456 100644\n--- a/old.zig\n+++ b/old.zig\n", "--- a/old.zig\n+++ b/old.zig\n" }) |header| {
        var buffer: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "{s}@@ -1 +1 @@\n-before\n+after\n", .{header});
        var lines: Lines = .{ .text = source };
        const file = lines.next().?;
        try std.testing.expectEqual(.file, file.kind);
        try std.testing.expectEqualStrings("old.zig", file.text);
        try std.testing.expectEqualDeep([2]u32{ 1, 1 }, lines.counts());
        try std.testing.expectEqual(.hunk, lines.next().?.kind);
    }
}

test "diff file summaries stop at boundaries and unpaired header-like code stays visible" {
    var lines: Lines = .{ .text = "Deleted old.zig\n-old\nAdded new.zig\n+one\n+two\n--- literal\n+++ literal\n" };
    _ = lines.next();
    try std.testing.expectEqualDeep([2]u32{ 0, 1 }, lines.counts());
    _ = lines.next();
    _ = lines.next();
    try std.testing.expectEqualDeep([2]u32{ 2, 0 }, lines.counts());
    var partial: Lines = .{ .text = "--- literal\n+ordinary\n+++ literal" };
    try std.testing.expectEqualStrings("-- literal", partial.next().?.text);
    try std.testing.expectEqualStrings("ordinary", partial.next().?.text);
    try std.testing.expectEqualStrings("++ literal", partial.next().?.text);
    try std.testing.expect(partial.next() == null);
}
