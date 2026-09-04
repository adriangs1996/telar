//! Owned, bounded link values crossing client callbacks and worker tasks.

const std = @import("std");
const core = @import("telar-core");

const link = core.link;

pub const Target = struct {
    scheme: link.Scheme,
    storage: [link.max_uri_bytes]u8 = undefined,
    len: u16,

    /// Copies one classified URI into worker-safe inline storage.
    ///
    /// ```zig
    /// const target = try Target.init("https://example.com");
    /// ```
    pub fn init(text: []const u8) !Target {
        const scheme = link.classify(text) orelse return error.InvalidLink;
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
};

test "targets own one classified URI" {
    const target = try Target.init("https://example.com/path");

    try std.testing.expectEqual(link.Scheme.https, target.scheme);
    try std.testing.expectEqualStrings("https://example.com/path", target.uri());
    try std.testing.expectError(error.InvalidLink, Target.init("ssh://example.com"));
}
