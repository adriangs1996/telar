//! Delivery of runtime-approved clipboard bytes through the host clipboard port.

const PaneClipboardCapture = @import("PaneClipboardCapture.zig");
const Handler = @import("PaneClipboardHandler.zig");
const std = @import("std");

test "clipboard delivery preserves validation and host failure without a terminal writer" {
    var capture: PaneClipboardCapture = .{};
    const handler: Handler = .{ .clipboard = .{ .context = &capture, .set = PaneClipboardCapture.set } };
    try std.testing.expectError(error.UnexpectedPane, handler.execute(.{ .pane_id = .invalid, .bytes = "hello" }));
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    try handler.execute(.{ .pane_id = @enumFromInt(1), .bytes = "hello" });
    try std.testing.expectEqualStrings("hello", capture.bytes[0..capture.len]);
    capture.fail = true;
    try std.testing.expectError(error.ClipboardUnavailable, handler.execute(.{ .pane_id = @enumFromInt(1), .bytes = "hello" }));
}
