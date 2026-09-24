//! Owned, bounded link values crossing client callbacks and worker tasks.

const urlscan = @import("urlscan");
const data = @import("model");
const std = @import("std");

test "targets own one classified URI" {
    const target = try data.LinkTarget.init("https://example.com/path");

    try std.testing.expectEqual(urlscan.Scheme.https, target.scheme);
    try std.testing.expectEqualStrings("https://example.com/path", target.uri());
    try std.testing.expectError(error.InvalidLink, data.LinkTarget.init("javascript:alert(1)"));
}
