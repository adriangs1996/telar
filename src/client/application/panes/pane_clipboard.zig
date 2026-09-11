//! Delivery of runtime-approved clipboard bytes through the host clipboard port.
const std = @import("std");
const schema = @import("telar-core").schema;

pub const Clipboard = @import("Clipboard.zig");

pub const Handler = @import("Handler.zig");

const Capture = @import("PaneClipboardCapture.zig");

test "clipboard delivery preserves validation and host failure without a terminal writer" {
    var capture: Capture = .{};
    const handler: Handler = .{ .clipboard = .{ .context = &capture, .set = Capture.set } };
    try std.testing.expectError(error.UnexpectedPane, handler.execute(.{ .pane_id = .invalid, .bytes = "hello" }));
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    try handler.execute(.{ .pane_id = @enumFromInt(1), .bytes = "hello" });
    try std.testing.expectEqualStrings("hello", capture.bytes[0..capture.len]);
    capture.fail = true;
    try std.testing.expectError(error.ClipboardUnavailable, handler.execute(.{ .pane_id = @enumFromInt(1), .bytes = "hello" }));
}
