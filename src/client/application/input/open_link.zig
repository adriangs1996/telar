//! Application policy for dispatching one classified link target.

const OpenLinkCapture = @import("OpenLinkCapture.zig");
const OpenLinkHandler = @import("OpenLinkHandler.zig");
const TargetType = @import("../../links/LinkTarget.zig");
const std = @import("std");

test "link dispatch decodes files and preserves web URIs" {
    var capture: OpenLinkCapture = .{};
    var handler: OpenLinkHandler = .{ .effects = capture.effects() };

    try handler.execute(try TargetType.init("file:///tmp/a%20b.txt"));
    try std.testing.expectEqualStrings("/tmp/a b.txt", capture.file.?.slice());
    try std.testing.expect(capture.external == null);

    capture = .{};
    handler = .{ .effects = capture.effects() };
    try handler.execute(try TargetType.init("https://example.com/a"));
    try std.testing.expectEqualStrings("https://example.com/a", capture.external.?.uri());
    try std.testing.expect(capture.file == null);
}
