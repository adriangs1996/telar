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
