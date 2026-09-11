const Target = @This();
const source_namespace = @import("target_support.zig");
const std = @import("std");
scheme: source_namespace.link.Scheme,
storage: [source_namespace.link.max_uri_bytes]u8 = undefined,
len: u16,

/// Copies one classified URI into worker-safe inline storage.
///
/// ```zig
/// const target = try Target.init("https://example.com");
/// ```
pub fn init(text: []const u8) !Target {
    const scheme = source_namespace.link.classify(text) orelse return error.InvalidLink;
    var target: Target = .{
        .scheme = scheme,
        .len = @intCast(text.len),
    };
    @memcpy(target.storage[0..text.len], text);

    return target;
}

pub fn uri(target: *const Target) []const u8 {
    return target.storage[0..target.len];
}

pub fn eql(a: *const Target, b: *const Target) bool {
    return a.scheme == b.scheme and std.mem.eql(u8, a.uri(), b.uri());
}
