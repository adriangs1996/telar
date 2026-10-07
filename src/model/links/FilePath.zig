const urlscan = @import("urlscan");
const LinkTarget = @import("LinkTarget.zig");
const std = @import("std");
const file_uri = @import("file_uri.zig");
const FilePath = @This();

// SAFETY: Successful constructors copy or decode the path into storage before returning; slice exposes only len bytes.
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
