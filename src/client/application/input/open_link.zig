//! Application policy for dispatching one classified link target.

const std = @import("std");
const link_capability = @import("../../links/root.zig");

pub const Effects = @import("OpenLinkEffects.zig");

pub const OpenLinkHandler = @import("OpenLinkHandler.zig");

const Capture = @import("OpenLinkCapture.zig");

test "link dispatch decodes files and preserves web URIs" {
    var capture: Capture = .{};
    var handler: OpenLinkHandler = .{ .effects = capture.effects() };

    try handler.execute(try link_capability.Target.init("file:///tmp/a%20b.txt"));
    try std.testing.expectEqualStrings("/tmp/a b.txt", capture.file.?.slice());
    try std.testing.expect(capture.external == null);

    capture = .{};
    handler = .{ .effects = capture.effects() };
    try handler.execute(try link_capability.Target.init("https://example.com/a"));
    try std.testing.expectEqualStrings("https://example.com/a", capture.external.?.uri());
    try std.testing.expect(capture.file == null);
}
