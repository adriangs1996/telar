//! Expands a typed working directory into an absolute path without touching
//! the filesystem: `~` and `~/…` use HOME, `$VAR` and `${VAR}` use the
//! process environment, and a relative path resolves against the focused
//! pane's directory. `.` and `..` segments are resolved lexically so the
//! result is the path the workspace will show, not what was typed. Output
//! is bounded by `max_path_bytes`.

const std = @import("std");
const max_path_bytes_module = @import("../model/PathCompletionResult.zig").max_path_bytes;
const ExpansionInput = @import("ExpansionInput.zig");

pub const max_path_bytes = max_path_bytes_module;

/// ```zig
/// const path = try expand(.{ .text = "~/sandbox/$PROJECT", .environ = environ, .base = pane_cwd }, &buffer);
/// ```
pub fn expand(input: ExpansionInput, buffer: *[max_path_bytes]u8) ![]const u8 {
    var scratch: [max_path_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&scratch);
    const text = std.mem.trim(u8, input.text, " ");
    var rest = text;
    if (std.mem.eql(u8, rest, "~") or std.mem.startsWith(u8, rest, "~/")) {
        const home = input.environ.getPosix("HOME") orelse return error.HomeUnavailable;
        try writeChecked(&writer, home);
        rest = rest[1..];
    }

    var index: usize = 0;
    while (index < rest.len) {
        if (rest[index] != '$') {
            const next = std.mem.indexOfScalarPos(u8, rest, index, '$') orelse rest.len;
            try writeChecked(&writer, rest[index..next]);
            index = next;
            continue;
        }

        const name_start = if (index + 1 < rest.len and rest[index + 1] == '{') index + 2 else index + 1;
        var name_end = name_start;
        while (name_end < rest.len and isNameByte(rest[name_end])) : (name_end += 1) {}
        if (name_end == name_start) {
            try writeChecked(&writer, "$");
            index += 1;
            continue;
        }
        if (name_start == index + 2) {
            if (name_end >= rest.len or rest[name_end] != '}') {
                return error.UnterminatedVariable;
            }
        }

        const value = input.environ.getPosix(rest[name_start..name_end]) orelse return error.UnknownVariable;
        try writeChecked(&writer, value);
        index = if (name_start == index + 2) name_end + 1 else name_end;
    }

    const expanded = writer.buffered();
    var anchored: std.Io.Writer = .fixed(buffer);
    if (expanded.len == 0 or expanded[0] != '/') {
        if (input.base.len == 0 or input.base[0] != '/') {
            return error.BaseUnavailable;
        }

        try writeChecked(&anchored, input.base);
        if (expanded.len != 0) {
            try writeChecked(&anchored, "/");
        }
    }
    try writeChecked(&anchored, expanded);

    return collapse(anchored.buffered());
}

/// Normalizes an absolute path in place: repeated separators and `.` vanish,
/// `..` drops the previous segment (never above the root), and the trailing
/// separator goes, keeping "/" for the root.
fn collapse(path: []u8) []const u8 {
    var len: usize = 0;
    var start: usize = 0;
    while (start <= path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
        const segment = path[start..end];
        start = end + 1;
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) {
            continue;
        }

        if (std.mem.eql(u8, segment, "..")) {
            len = std.mem.lastIndexOfScalar(u8, path[0..len], '/') orelse 0;
            continue;
        }

        path[len] = '/';
        std.mem.copyForwards(u8, path[len + 1 .. len + 1 + segment.len], segment);
        len += 1 + segment.len;
    }

    return if (len == 0) path[0..1] else path[0..len];
}

fn writeChecked(writer: *std.Io.Writer, bytes: []const u8) !void {
    writer.writeAll(bytes) catch return error.PathTooLong;
}

fn isNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Whether a typed directory ends with a separator, which asks the
/// completion list for its children instead of its siblings.
pub fn endsWithSeparator(text: []const u8) bool {
    return text.len != 0 and text[text.len - 1] == '/';
}

/// The last path segment, used as the default context name.
/// Example: `basename("/work/telar")` is `"telar"`.
pub fn basename(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const split = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[split + 1 ..];
}

const TestEnvironment = @import("TestEnvironment.zig");

test "expansion resolves home, variables and relative paths against the pane" {
    var environment = try TestEnvironment.init(&.{ .{ "HOME", "/home/me" }, .{ "PROJECT", "telar" } });
    defer environment.deinit();
    const environ = environment.environ();
    var buffer: [max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("/home/me", try expand(.{ .text = "~", .environ = environ, .base = "/work" }, &buffer));
    try std.testing.expectEqualStrings("/home/me/sandbox/telar", try expand(.{ .text = "~/sandbox/$PROJECT/", .environ = environ, .base = "/work" }, &buffer));
    try std.testing.expectEqualStrings("/home/me/telar-x", try expand(.{ .text = "${HOME}/${PROJECT}-x", .environ = environ, .base = "/work" }, &buffer));
    try std.testing.expectEqualStrings("/work/new", try expand(.{ .text = "new", .environ = environ, .base = "/work" }, &buffer));
    try std.testing.expectEqualStrings("/work", try expand(.{ .text = "", .environ = environ, .base = "/work" }, &buffer));
    try std.testing.expectEqualStrings("/a/b", try expand(.{ .text = "//a//b/", .environ = environ, .base = "/work" }, &buffer));
    try std.testing.expectEqualStrings("/", try expand(.{ .text = "/", .environ = environ, .base = "/work" }, &buffer));
    try std.testing.expectEqualStrings("/home/me/sandbox/gwagent", try expand(.{ .text = "../gwagent", .environ = environ, .base = "/home/me/sandbox/telar" }, &buffer));
    try std.testing.expectEqualStrings("/home/me/sandbox/telar", try expand(.{ .text = "./", .environ = environ, .base = "/home/me/sandbox/telar" }, &buffer));
    try std.testing.expectEqualStrings("/a/c", try expand(.{ .text = "/a/./b/../c/.", .environ = environ, .base = "/work" }, &buffer));
    try std.testing.expectEqualStrings("/", try expand(.{ .text = "/../..", .environ = environ, .base = "/work" }, &buffer));
    try std.testing.expectEqualStrings("/x", try expand(.{ .text = "../../../x", .environ = environ, .base = "/work" }, &buffer));
    try std.testing.expectEqualStrings("/tmp/$", try expand(.{ .text = "/tmp/$", .environ = environ, .base = "/work" }, &buffer));

    try std.testing.expectError(error.UnknownVariable, expand(.{ .text = "$MISSING/x", .environ = environ, .base = "/work" }, &buffer));
    try std.testing.expectError(error.UnterminatedVariable, expand(.{ .text = "${HOME", .environ = environ, .base = "/work" }, &buffer));
    try std.testing.expectError(error.BaseUnavailable, expand(.{ .text = "new", .environ = environ, .base = "" }, &buffer));
    try std.testing.expectError(error.HomeUnavailable, expand(.{ .text = "~/x", .environ = .empty, .base = "/work" }, &buffer));
    const long = [_]u8{'x'} ** max_path_bytes;
    try std.testing.expectError(error.PathTooLong, expand(.{ .text = &long, .environ = environ, .base = "/work" }, &buffer));
}

test "basename ignores trailing separators" {
    try std.testing.expectEqualStrings("telar", basename("/work/telar/"));
    try std.testing.expectEqualStrings("telar", basename("telar"));
    try std.testing.expectEqualStrings("", basename("/"));
    try std.testing.expect(endsWithSeparator("/work/"));
    try std.testing.expect(!endsWithSeparator("/work"));
}
