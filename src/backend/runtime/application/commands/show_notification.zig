//! Application command for broadcasting one bounded notification.

const std = @import("std");
const core = @import("telar-core");

pub const schema = core.schema;

pub const ShowNotification = @import("ShowNotification.zig");

pub const ShowNotificationResult = @import("ShowNotificationResult.zig");

pub const NotificationPublisher = @import("NotificationPublisher.zig");

pub const ShowNotificationExecutor = @import("ShowNotificationExecutor.zig");

pub const ShowNotificationHandler = @import("ShowNotificationHandler.zig");

const PublicationCapture = @import("ShowNotificationPublicationCapture.zig");

test "ShowNotificationHandler publishes one owned bounded notification" {
    var capture: PublicationCapture = .{ .delivered_clients = 3 };
    var handler: ShowNotificationHandler = .{ .notifications = capture.publisher() };
    var title = [_]u8{ 'B', 'u', 'i', 'l', 'd' };
    var message = [_]u8{ 'D', 'o', 'n', 'e' };

    const result = handler.executor().execute(.{ .notification = .{
        .level = .success,
        .duration_ms = 2500,
        .target = .{ .pane = try schema.id.pane(42) },
        .title = &title,
        .message = &message,
    } });
    @memset(&title, 'x');
    @memset(&message, 'x');

    try std.testing.expectEqual(@as(usize, 1), capture.call_count);
    try std.testing.expectEqual(@as(u8, 3), result.delivered_clients);
    try std.testing.expectEqual(schema.NotificationLevel.success, capture.level);
    try std.testing.expectEqual(@as(u32, 2500), capture.duration_ms);
    try std.testing.expectEqual(try schema.id.pane(42), capture.target.pane);
    try std.testing.expectEqualStrings("Build", capture.titleSlice());
    try std.testing.expectEqualStrings("Done", capture.messageSlice());
}

test "ShowNotificationHandler preserves a zero-recipient result" {
    var capture: PublicationCapture = .{ .delivered_clients = 0 };
    var handler: ShowNotificationHandler = .{ .notifications = capture.publisher() };

    const result = handler.execute(.{ .notification = .{ .title = "Nobody" } });

    try std.testing.expectEqual(@as(usize, 1), capture.call_count);
    try std.testing.expectEqual(@as(u8, 0), result.delivered_clients);
}
