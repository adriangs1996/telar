const max_uri_bytes_module = @import("telar-core").max_uri_bytes;
const TargetType = @import("LinkTarget.zig");
const std = @import("std");
const file_uri = @import("file_uri.zig");
const FilePath = @This();

storage: [max_uri_bytes_module]u8 = undefined,
len: u16,

/// Decodes a local `file://` target without filesystem access.
///
/// ```zig
/// const path = try FilePath.init(&target);
/// ```
pub fn init(target: *const TargetType) !FilePath {
    if (target.scheme != .file) {
        return error.NotFileLink;
    }

    const parsed = try std.Uri.parse(target.uri());
    if (parsed.user != null or parsed.password != null or parsed.port != null or parsed.query != null or parsed.fragment != null) {
        return error.InvalidFileLink;
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

    var path: FilePath = .{ .len = 0 };
    const raw_path = try parsed.path.toRaw(&path.storage);
    if (raw_path.len == 0 or raw_path[0] != '/' or std.mem.indexOfScalar(u8, raw_path, 0) != null) {
        return error.InvalidFileLink;
    }

    if (raw_path.ptr != path.storage[0..].ptr) {
        @memcpy(path.storage[0..raw_path.len], raw_path);
    }
    path.len = @intCast(raw_path.len);

    return path;
}

pub fn slice(path: *const FilePath) []const u8 {
    return path.storage[0..path.len];
}
