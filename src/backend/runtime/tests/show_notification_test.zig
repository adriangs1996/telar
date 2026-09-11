//! Vertical tests for notification publication and requester confirmation.

const ResponseQueue = @import("../delivery/ResponseQueue.zig");
const ShowNotificationTestBroadcaster = @import("ShowNotificationTestBroadcaster.zig");
const ShowNotificationHandlerType = @import("../application/commands/ShowNotificationHandler.zig");
const PumpCapture = @import("PumpCapture.zig");
const ShowNotificationController = @import("../entrypoints/requests/ShowNotificationController.zig");
const RequestIdType = @import("telar-core").RequestId;
const pane_module = @import("telar-core").pane;
const std = @import("std");
const NotificationLevelType = @import("telar-core").NotificationLevel;

fn fill(queue: *ResponseQueue) !void {
    while (queue.len < queue.items.len) {
        try queue.push(.{ .notification_shown = .{
            .request_id = @enumFromInt(queue.len + 1),
            .delivered_clients = 0,
        } });
    }
}

test "show notification confirms only recipients that accepted owned delivery" {
    var requester: ResponseQueue = .{};
    var first: ResponseQueue = .{};
    var saturated: ResponseQueue = .{};
    try fill(&saturated);
    var third: ResponseQueue = .{};
    var broadcaster: ShowNotificationTestBroadcaster = .{ .recipients = .{ &first, &saturated, &third } };
    var handler: ShowNotificationHandlerType = .{
        .notifications = broadcaster.publisher(),
    };
    var pump: PumpCapture = .{};
    var controller = ShowNotificationController.init(
        &requester,
        handler.executor(),
        pump.delivery(),
    );
    var title = [_]u8{ 'B', 'u', 'i', 'l', 'd' };
    var message = [_]u8{ 'D', 'o', 'n', 'e' };
    const request_id: RequestIdType = @enumFromInt(17);

    try controller.showNotification(.{
        .request_id = request_id,
        .notification = .{
            .level = .success,
            .duration_ms = 2500,
            .target = .{ .pane = try pane_module(42) },
            .title = &title,
            .message = &message,
        },
    });
    @memset(&title, 'x');
    @memset(&message, 'x');

    try std.testing.expectEqual(@as(usize, 1), broadcaster.call_count);
    const confirmation = requester.peek().?.notification_shown;
    try std.testing.expectEqual(request_id, confirmation.request_id);
    try std.testing.expectEqual(@as(u8, 2), confirmation.delivered_clients);
    try std.testing.expectEqual(@as(usize, 1), pump.count);
    try std.testing.expectEqual(@as(u64, 1), saturated.dropped);
    try std.testing.expectEqual(@as(u8, saturated.items.len), saturated.len);

    for ([_]*ResponseQueue{ &first, &third }) |recipient| {
        const notification = recipient.peek().?.notification.view();
        try std.testing.expectEqual(NotificationLevelType.success, notification.level);
        try std.testing.expectEqual(@as(u32, 2500), notification.duration_ms);
        try std.testing.expectEqual(try pane_module(42), notification.target.pane);
        try std.testing.expectEqualStrings("Build", notification.title);
        try std.testing.expectEqualStrings("Done", notification.message);
    }
}
