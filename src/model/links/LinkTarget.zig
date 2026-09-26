const urlscan = @import("urlscan");
const std = @import("std");
const Target = @This();

scheme: urlscan.Scheme,
storage: [urlscan.max_uri_bytes]u8 = undefined,
len: u16,

/// Copies one classified URI into worker-safe inline storage.
///
/// ```zig
/// const target = try Target.init("https://example.com");
/// ```
pub fn init(text: []const u8) !Target {
    const scheme = urlscan.classify(text) orelse return error.InvalidLink;
    var target: Target = .{
        .scheme = scheme,
        .len = @intCast(text.len),
    };
    @memcpy(target.storage[0..text.len], text);

    return target;
}

/// Copies one local path found in prose by `urlscan.pathAt`, with its
/// `:line[:column]` suffix. It is not a URI, so only the file opener takes it.
///
/// ```zig
/// const target = try Target.initPath("src/main.zig:12");
/// ```
pub fn initPath(text: []const u8) !Target {
    if (text.len == 0 or text.len > urlscan.max_uri_bytes or !std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidLink;
    }

    for (text) |byte| {
        if (std.ascii.isControl(byte)) {
            return error.InvalidLink;
        }
    }

    var target: Target = .{
        .scheme = .path,
        .len = @intCast(text.len),
    };
    @memcpy(target.storage[0..text.len], text);

    return target;
}

pub fn uri(self: *const Target) []const u8 {
    return self.storage[0..self.len];
}

pub fn eql(self: *const Target, b: *const Target) bool {
    return self.scheme == b.scheme and std.mem.eql(
        u8,
        self.uri(),
        b.uri(),
    );
}
