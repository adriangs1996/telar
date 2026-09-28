//! Recognition of local file paths in prose, the way compilers and coding
//! agents print them: absolute, home (`~/`), dot-relative (`./`, `../`) or
//! project-relative with a file extension, optionally followed by
//! `:line[:column]`. Recognition is lexical; whether the file exists is the
//! opener's question.

const std = @import("std");
const uri = @import("uri.zig");
const Match = @import("Match.zig");
const Location = @import("Location.zig");

/// Nine decimal digits always fit a `u32`; longer numbers are not positions.
const max_number_digits = 9;

/// Every byte of a multi-byte UTF-8 sequence is at or above this one.
const first_non_ascii = 0x80;

/// Finds the path, with its `:line[:column]` suffix, containing `byte_offset`.
/// A path never contains `:`, so each colon-separated segment of a token is
/// a candidate and the digits after it are its position.
///
/// ```zig
/// const found = urlscan.pathAt("see src/main.zig:12 for details", 6).?;
/// const text = found.text("see src/main.zig:12 for details"); // "src/main.zig:12"
/// ```
pub fn pathAt(line: []const u8, byte_offset: usize) ?Match {
    if (byte_offset >= line.len or !isTokenByte(line[byte_offset])) {
        return null;
    }

    var start = byte_offset;
    while (start > 0 and isTokenByte(line[start - 1])) {
        start -= 1;
    }

    var end = byte_offset + 1;
    while (end < line.len and isTokenByte(line[end])) {
        end += 1;
    }

    // An overlong token never becomes a truncated destination.
    if (end - start > uri.max_uri_bytes) {
        return null;
    }

    var segment_start = start;
    while (segment_start < end) {
        const segment_end = std.mem.indexOfScalarPos(u8, line[0..end], segment_start, ':') orelse end;
        const suffix_end = positionEnd(line[0..end], segment_end);
        const path_start = trimLeading(line[segment_start..segment_end]) + segment_start;
        const path_end = if (suffix_end == segment_end) trimTrailing(line[path_start..segment_end]) + path_start else segment_end;
        const match_end = if (suffix_end == segment_end) path_end else suffix_end;
        if (looksLikePath(line[path_start..path_end], suffix_end != segment_end) and byte_offset >= path_start and byte_offset < match_end) {
            return .{
                .scheme = .path,
                .start = path_start,
                .end = match_end,
            };
        }

        segment_start = @max(segment_end, suffix_end) + 1;
    }

    return null;
}

/// Splits a recognized path from its `:line[:column]` suffix.
///
/// ```zig
/// const location = urlscan.locatePath("src/main.zig:12:3");
/// // location.path == "src/main.zig", location.line == 12, location.column == 3
/// ```
pub fn locatePath(text: []const u8) Location {
    const separator = std.mem.indexOfScalar(u8, text, ':') orelse return .{
        .path = text,
    };

    var location: Location = .{
        .path = text[0..separator],
    };
    const line_digits = numberLength(text[separator + 1 ..]);
    location.line = parseNumber(text[separator + 1 ..][0..line_digits]);
    const column_start = separator + 1 + line_digits;
    if (line_digits != 0 and column_start < text.len and text[column_start] == ':') {
        const column_digits = numberLength(text[column_start + 1 ..]);
        location.column = parseNumber(text[column_start + 1 ..][0..column_digits]);
    }

    return location;
}

/// Reads a line from a `file://` fragment: `12`, `L12`, `L12:3`, `L12C3`
/// or a range such as `L12-L20`, which points at its first line. Any other
/// fragment names something that is not a position and returns null.
///
/// ```zig
/// const location = urlscan.locateFragment("/tmp/a.zig", "L12").?;
/// ```
pub fn locateFragment(path: []const u8, fragment: []const u8) ?Location {
    var rest = fragment;
    if (rest.len != 0 and (rest[0] == 'L' or rest[0] == 'l')) {
        rest = rest[1..];
    }

    const line_digits = numberLength(rest);
    if (line_digits == 0) {
        return null;
    }

    var location: Location = .{
        .path = path,
        .line = parseNumber(rest[0..line_digits]),
    };
    rest = rest[line_digits..];
    if (rest.len != 0 and (rest[0] == ':' or rest[0] == 'C' or rest[0] == 'c')) {
        const column_digits = numberLength(rest[1..]);
        if (column_digits == 0) {
            return null;
        }

        location.column = parseNumber(rest[1..][0..column_digits]);
        rest = rest[1 + column_digits ..];
    }

    if (rest.len != 0 and rest[0] != '-') {
        return null;
    }

    return location;
}

/// The end of the `:line[:column]` suffix that starts at `colon`, or `colon`
/// itself when the digits after it are not a position.
fn positionEnd(token: []const u8, colon: usize) usize {
    if (colon >= token.len) {
        return colon;
    }

    const line_digits = numberLength(token[colon + 1 ..]);
    if (line_digits == 0) {
        return colon;
    }

    const line_end = colon + 1 + line_digits;
    if (line_end >= token.len or token[line_end] != ':') {
        return line_end;
    }

    const column_digits = numberLength(token[line_end + 1 ..]);
    if (column_digits == 0) {
        return line_end;
    }

    return line_end + 1 + column_digits;
}

fn looksLikePath(candidate: []const u8, positioned: bool) bool {
    if (candidate.len < 2 or candidate[0] == '-' or candidate[0] == '+' or std.mem.startsWith(u8, candidate, "//")) {
        return false;
    }

    if (std.mem.indexOfAny(u8, candidate, alphanumeric) == null) {
        return false;
    }

    if (candidate[0] == '/' or std.mem.startsWith(u8, candidate, "~/") or std.mem.startsWith(u8, candidate, "./") or std.mem.startsWith(u8, candidate, "../")) {
        return true;
    }

    // Bare words with slashes are too often prose ("and/or"); a project path
    // names a file with an extension. A bare file name needs a line number.
    const separator = std.mem.lastIndexOfScalar(u8, candidate, '/');
    if (separator == null and !positioned) {
        return false;
    }

    const name = if (separator) |index| candidate[index + 1 ..] else candidate;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    return dot != 0 and dot + 1 < name.len;
}

/// Non-ASCII glued to a path is almost always decoration a TUI draws around
/// it (box drawing, bullets, arrows, ellipses), so a path starts and ends on
/// ASCII; non-ASCII names in between are kept.
fn trimLeading(candidate: []const u8) usize {
    var start: usize = 0;
    while (start < candidate.len and candidate[start] >= first_non_ascii) {
        start += 1;
    }

    return start;
}

/// Sentence punctuation and decoration after a path belong to the prose.
fn trimTrailing(candidate: []const u8) usize {
    var end = candidate.len;
    while (end != 0 and (candidate[end - 1] == '.' or candidate[end - 1] >= first_non_ascii)) {
        end -= 1;
    }

    return end;
}

fn numberLength(text: []const u8) usize {
    var length: usize = 0;
    while (length < text.len and std.ascii.isDigit(text[length])) {
        length += 1;
    }

    return if (length > max_number_digits) 0 else length;
}

fn parseNumber(digits: []const u8) u32 {
    return std.fmt.parseInt(u32, digits, 10) catch 0;
}

const alphanumeric = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

/// Bytes a path token may contain: the `:` of its position suffix, and
/// UTF-8 continuation for non-ASCII names.
fn isTokenByte(byte: u8) bool {
    return isPathByte(byte) or byte == ':';
}

fn isPathByte(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '/', '.', '_', '-', '~', '+', '@', '%' => true,
        else => byte >= first_non_ascii,
    };
}

test "paths agents print are recognized with their position" {
    const cases = [_]struct { line: []const u8, cursor: []const u8, expected: []const u8 }{
        .{ .line = "Look at src/gui/routing.zig:435.", .cursor = "routing", .expected = "src/gui/routing.zig:435" },
        .{ .line = "en ~/.claude/settings.json.", .cursor = "claude", .expected = "~/.claude/settings.json" },
        .{ .line = "`src/main.zig:12:3`", .cursor = "main", .expected = "src/main.zig:12:3" },
        .{ .line = "error: ./a/b.c:7:2: expected", .cursor = "b.c", .expected = "./a/b.c:7:2" },
        .{ .line = "(/tmp/report.md)", .cursor = "report", .expected = "/tmp/report.md" },
        .{ .line = "see main.zig:40 now", .cursor = "main", .expected = "main.zig:40" },
        .{ .line = "../lib/x.zig:5-9", .cursor = "x.zig", .expected = "../lib/x.zig:5" },
        .{ .line = "docs/flows/link-opening.md", .cursor = "flows", .expected = "docs/flows/link-opening.md" },
        .{ .line = "\u{2502}src/a.zig\u{2026}", .cursor = "a.zig", .expected = "src/a.zig" },
        .{ .line = "docs/dise\u{f1}o.md:3", .cursor = "docs", .expected = "docs/dise\u{f1}o.md:3" },
    };

    for (cases) |case| {
        const offset = std.mem.indexOf(u8, case.line, case.cursor).?;
        const found = pathAt(case.line, offset) orelse return error.TestExpectedPath;
        try std.testing.expectEqual(uri.Scheme.path, found.scheme);
        try std.testing.expectEqualStrings(case.expected, found.text(case.line));
    }
}

test "the position suffix belongs to the link under every byte" {
    const line = "at src/a.zig:12:3 end";
    const expected = "src/a.zig:12:3";
    const first = std.mem.indexOf(u8, line, expected).?;
    for (first..first + expected.len) |offset| {
        const found = pathAt(line, offset) orelse return error.TestExpectedPath;
        try std.testing.expectEqualStrings(expected, found.text(line));
    }
}

test "prose and non-paths are not paths" {
    const cases = [_][]const u8{
        "and/or",
        "main.zig",
        "1.2.3",
        "-rf/tmp.x",
        "//comment.txt",
        "a/b",
        "src/",
        "...",
        "v1.2/x",
    };

    for (cases) |case| {
        try std.testing.expect(pathAt(case, 1) == null);
    }
}

test "a label before a colon is not part of the path" {
    const line = "error:src/a.zig:10";
    const found = pathAt(line, std.mem.indexOf(u8, line, "a.zig").?).?;
    try std.testing.expectEqualStrings("src/a.zig:10", found.text(line));
    try std.testing.expect(pathAt(line, 1) == null);
}

test "overlong path tokens never become truncated destinations" {
    const long = "/" ++ "a" ** uri.max_uri_bytes ++ ".txt";
    try std.testing.expect(pathAt(long, 3) == null);
}

test "locating splits the position suffix from the path" {
    const plain = locatePath("~/.claude/settings.json");
    try std.testing.expectEqualStrings("~/.claude/settings.json", plain.path);
    try std.testing.expectEqual(@as(u32, 0), plain.line);

    const positioned = locatePath("src/a.zig:435:7");
    try std.testing.expectEqualStrings("src/a.zig", positioned.path);
    try std.testing.expectEqual(@as(u32, 435), positioned.line);
    try std.testing.expectEqual(@as(u32, 7), positioned.column);

    const line_only = locatePath("a.zig:9");
    try std.testing.expectEqual(@as(u32, 9), line_only.line);
    try std.testing.expectEqual(@as(u32, 0), line_only.column);
}

test "fragments name a line, a column or a range start" {
    const cases = [_]struct { fragment: []const u8, line: u32, column: u32 }{
        .{ .fragment = "12", .line = 12, .column = 0 },
        .{ .fragment = "L12", .line = 12, .column = 0 },
        .{ .fragment = "L12:3", .line = 12, .column = 3 },
        .{ .fragment = "L12C3", .line = 12, .column = 3 },
        .{ .fragment = "L12-L20", .line = 12, .column = 0 },
    };

    for (cases) |case| {
        const location = locateFragment("/tmp/a", case.fragment) orelse return error.TestExpectedLocation;
        try std.testing.expectEqualStrings("/tmp/a", location.path);
        try std.testing.expectEqual(case.line, location.line);
        try std.testing.expectEqual(case.column, location.column);
    }

    for ([_][]const u8{ "", "L", "section", "L12x", "L12:", "L1234567890" }) |fragment| {
        try std.testing.expect(locateFragment("/tmp/a", fragment) == null);
    }
}
