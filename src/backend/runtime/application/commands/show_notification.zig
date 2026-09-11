//! Application command for broadcasting one bounded notification.

const ShowNotificationPublicationCapture = @import("ShowNotificationPublicationCapture.zig");
const ShowNotificationHandler = @import("ShowNotificationHandler.zig");
const pane_module = @import("telar-core").pane;
const std = @import("std");
const NotificationLevelType = @import("telar-core").NotificationLevel;

test "ShowNotificationHandler publishes one owned bounded notification" {
    var capture: ShowNotificationPublicationCapture = .{ .delivered_clients = 3 };
    var handler: ShowNotificationHandler = .{ .notifications = capture.publisher() };
    var title = [_]u8{ 'B', 'u', 'i', 'l', 'd' };
    var message = [_]u8{ 'D', 'o', 'n', 'e' };

    const result = handler.executor().execute(.{ .notification = .{
        .level = .success,
        .duration_ms = 2500,
        .target = .{ .pane = try pane_module(42) },
        .title = &title,
        .message = &message,
    } });
    @memset(&title, 'x');
    @memset(&message, 'x');

    try std.testing.expectEqual(@as(usize, 1), capture.call_count);
    try std.testing.expectEqual(@as(u8, 3), result.delivered_clients);
    try std.testing.expectEqual(NotificationLevelType.success, capture.level);
    try std.testing.expectEqual(@as(u32, 2500), capture.duration_ms);
    try std.testing.expectEqual(try pane_module(42), capture.target.pane);
    try std.testing.expectEqualStrings("Build", capture.titleSlice());
    try std.testing.expectEqualStrings("Done", capture.messageSlice());
}

test "ShowNotificationHandler preserves a zero-recipient result" {
    var capture: ShowNotificationPublicationCapture = .{ .delivered_clients = 0 };
    var handler: ShowNotificationHandler = .{ .notifications = capture.publisher() };

    const result = handler.execute(.{ .notification = .{ .title = "Nobody" } });

    try std.testing.expectEqual(@as(usize, 1), capture.call_count);
    try std.testing.expectEqual(@as(u8, 0), result.delivered_clients);
}
