//! Application policy for dispatching one classified link target.

const std = @import("std");
const link_capability = @import("../../../links/root.zig");

pub const Effects = struct {
    context: *anyopaque,
    open_file: *const fn (*anyopaque, link_capability.FilePath) anyerror!void,
    open_external: *const fn (*anyopaque, link_capability.Target) anyerror!void,
};

pub const OpenLinkHandler = struct {
    effects: Effects,

    /// Converts file URIs before dispatch and keeps host URLs unchanged.
    ///
    /// ```zig
    /// try handler.execute(target);
    /// ```
    pub fn execute(handler: *OpenLinkHandler, target: link_capability.Target) !void {
        switch (target.scheme) {
            .file => try handler.effects.open_file(
                handler.effects.context,
                try link_capability.FilePath.init(&target),
            ),
            .http, .https => try handler.effects.open_external(handler.effects.context, target),
        }
    }
};

const Capture = struct {
    file: ?link_capability.FilePath = null,
    external: ?link_capability.Target = null,

    fn effects(capture: *Capture) Effects {
        return .{
            .context = capture,
            .open_file = openFile,
            .open_external = openExternal,
        };
    }

    fn openFile(context: *anyopaque, path: link_capability.FilePath) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.file = path;
    }

    fn openExternal(context: *anyopaque, target: link_capability.Target) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.external = target;
    }
};

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
