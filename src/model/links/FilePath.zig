const urlscan = @import("urlscan");
const LinkTarget = @import("LinkTarget.zig");
const std = @import("std");
const file_uri = @import("file_uri.zig");
const FilePath = @This();

storage: [urlscan.max_uri_bytes]u8 = undefined,
len: u16,
/// The line the link points at; zero when it names only the file.
line: u32 = 0,
/// The column on `line`; zero means its start.
column: u32 = 0,

/// Decodes a local `file://` target, or a path found in prose, without
/// filesystem access. A `file://` fragment such as `#L12` and a path's
/// `:12:3` suffix become the line and column. A path from prose may still be
/// relative or start at `~`; the opener anchors it.
///
/// ```zig
/// const path = try FilePath.init(&target);
/// ```
pub fn init(target: *const LinkTarget) !FilePath {
    return switch (target.scheme) {
        .file => initUri(target),
        .path => initProse(target),
        .http, .https, .external => error.NotFileLink,
    };
}

fn initProse(target: *const LinkTarget) !FilePath {
    const location = urlscan.locatePath(target.uri());
    if (location.path.len == 0 or location.path[0] == '-') {
        return error.InvalidFileLink;
    }

    var path: FilePath = .{
        .len = @intCast(location.path.len),
        .line = location.line,
        .column = if (location.line == 0) 0 else location.column,
    };
    @memcpy(path.storage[0..location.path.len], location.path);

    return path;
}

fn initUri(target: *const LinkTarget) !FilePath {
    const parsed = try std.Uri.parse(target.uri());
    if (parsed.user != null or parsed.password != null or parsed.port != null or parsed.query != null) {
        return error.InvalidFileLink;
    }

    var line: u32 = 0;
    var column: u32 = 0;
    if (parsed.fragment) |fragment| {
        const text = switch (fragment) {
            .raw, .percent_encoded => |value| value,
        };
        const location = urlscan.locateFragment("", text) orelse return error.InvalidFileLink;
        line = location.line;
        column = if (line == 0) 0 else location.column;
    }

    if (parsed.host) |host| {
        var host_storage: [std.Io.net.HostName.max_len]u8 = undefined;
        const raw_host = try host.toRaw(&host_storage);
        if (raw_host.len != 0 and !std.ascii.eqlIgnoreCase(raw_host, "localhost")) {
            return error.RemoteFileLink;
        }
    }

    const encoded_path = switch (parsed.path) {
        .raw, .percent_encoded => |value| value,
    };
    try file_uri.validateEscapes(encoded_path);

    var path: FilePath = .{
        .len = 0,
        .line = line,
        .column = column,
    };
    const raw_path = try parsed.path.toRaw(&path.storage);
    if (raw_path.len == 0 or raw_path[0] != '/' or std.mem.indexOfScalar(
        u8,
        raw_path,
        0,
    ) != null) {
        return error.InvalidFileLink;
    }

    if (raw_path.ptr != path.storage[0..].ptr) {
        @memcpy(path.storage[0..raw_path.len], raw_path);
    }
    path.len = @intCast(raw_path.len);

    return path;
}

pub fn slice(self: *const FilePath) []const u8 {
    return self.storage[0..self.len];
}

/// Accepts an absolute Markdown path or a validated local file URI.
/// Example: `const path = try FilePath.fromDestination("/tmp/report.md");`
pub fn fromDestination(text: []const u8) !FilePath {
    if (text.len == 0 or text.len > urlscan.max_uri_bytes or !std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidFileLink;
    }

    for (text) |byte| {
        if (std.ascii.isControl(byte)) {
            return error.InvalidFileLink;
        }
    }

    if (text[0] != '/') {
        const target = try LinkTarget.init(text);
        return init(&target);
    }

    var path: FilePath = .{
        .len = @intCast(text.len),
    };
    @memcpy(path.storage[0..text.len], text);
    return path;
}

test "file links carry the line and column they point at" {
    const fragment = try LinkTarget.init("file:///tmp/a%20b.zig#L12:3");
    const from_uri = try FilePath.init(&fragment);
    try std.testing.expectEqualStrings("/tmp/a b.zig", from_uri.slice());
    try std.testing.expectEqual(@as(u32, 12), from_uri.line);
    try std.testing.expectEqual(@as(u32, 3), from_uri.column);

    const prose = try LinkTarget.initPath("~/src/main.zig:40");
    const from_prose = try FilePath.init(&prose);
    try std.testing.expectEqualStrings("~/src/main.zig", from_prose.slice());
    try std.testing.expectEqual(@as(u32, 40), from_prose.line);
    try std.testing.expectEqual(@as(u32, 0), from_prose.column);

    const anchor = try LinkTarget.init("file:///tmp/a.md#usage");
    try std.testing.expectError(error.InvalidFileLink, FilePath.init(&anchor));
    const web = try LinkTarget.init("https://example.com/a.zig");
    try std.testing.expectError(error.NotFileLink, FilePath.init(&web));
}

test "message file destinations preserve literal paths and decode local URIs" {
    const path = try FilePath.fromDestination("/tmp/a b '$(touch nope)%.md");
    try std.testing.expectEqualStrings("/tmp/a b '$(touch nope)%.md", path.slice());
    const uri = try FilePath.fromDestination("file:///tmp/a%20b.md");
    try std.testing.expectEqualStrings("/tmp/a b.md", uri.slice());
    try std.testing.expectError(error.RemoteFileLink, FilePath.fromDestination("file://server/tmp/a"));
    try std.testing.expectError(error.InvalidFileLink, FilePath.fromDestination("/tmp/a\x00b"));
    try std.testing.expectError(error.InvalidLink, FilePath.fromDestination("-c"));
}
