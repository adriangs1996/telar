//! Owned, bounded link values crossing client callbacks and worker tasks.

const Target = @import("LinkTarget.zig");
const std = @import("std");
const SchemeType = @import("telar-core").Scheme;

test "targets own one classified URI" {
    const target = try Target.init("https://example.com/path");

    try std.testing.expectEqual(SchemeType.https, target.scheme);
    try std.testing.expectEqualStrings("https://example.com/path", target.uri());
    try std.testing.expectError(error.InvalidLink, Target.init("ssh://example.com"));
}
