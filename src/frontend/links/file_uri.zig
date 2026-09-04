//! Converts a local file URI into an owned path suitable for an argv entry.

const std = @import("std");
const core = @import("telar-core");
const target_mod = @import("target.zig");

const link = core.link;

pub const FilePath = struct {
    storage: [link.max_uri_bytes]u8 = undefined,
    len: u16,

    /// Decodes a local `file://` target without filesystem access.
    ///
    /// ```zig
    /// const path = try FilePath.init(&target);
    /// ```
    pub fn init(target: *const target_mod.Target) !FilePath {
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
        try validateEscapes(encoded_path);

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
};

fn validateEscapes(text: []const u8) !void {
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, index, '%')) |percent| {
        if (text.len - percent < 3 or !std.ascii.isHex(text[percent + 1]) or !std.ascii.isHex(text[percent + 2])) {
            return error.InvalidFileLink;
        }

        index = percent + 3;
    }
}

test "file paths decode local URIs and reject remote authority" {
    const target = try target_mod.Target.init("file://localhost/tmp/a%20b.txt");
    const path = try FilePath.init(&target);

    try std.testing.expectEqualStrings("/tmp/a b.txt", path.slice());

    const remote = try target_mod.Target.init("file://server/tmp/a.txt");
    try std.testing.expectError(error.RemoteFileLink, FilePath.init(&remote));
}

test "file paths reject query fragments malformed escapes and null bytes" {
    const query = try target_mod.Target.init("file:///tmp/a?line=2");
    const malformed = try target_mod.Target.init("file:///tmp/a%xx");
    const null_byte = try target_mod.Target.init("file:///tmp/a%00b");

    try std.testing.expectError(error.InvalidFileLink, FilePath.init(&query));
    try std.testing.expectError(error.InvalidFileLink, FilePath.init(&malformed));
    try std.testing.expectError(error.InvalidFileLink, FilePath.init(&null_byte));
}
