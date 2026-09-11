//! Owned, bounded link values crossing client callbacks and worker tasks.

const std = @import("std");
const core = @import("telar-core");

pub const link = core.link;

pub const Target = @import("Target.zig");

test "targets own one classified URI" {
    const target = try Target.init("https://example.com/path");

    try std.testing.expectEqual(link.Scheme.https, target.scheme);
    try std.testing.expectEqualStrings("https://example.com/path", target.uri());
    try std.testing.expectError(error.InvalidLink, Target.init("ssh://example.com"));
}
