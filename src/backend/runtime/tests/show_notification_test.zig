//! Vertical tests for notification publication and requester confirmation.

const std = @import("std");
const core = @import("telar-core");
const show_notification_commands = @import("../commands/show_notification.zig");
const show_notification_controller = @import("../controllers/show_notification.zig");
const delivery_mod = @import("../delivery/root.zig");

const schema = core.schema;
const PendingNotification = delivery_mod.PendingNotification;
const ResponseQueue = delivery_mod.ResponseQueue;

const Broadcaster = struct {
    recipients: [3]*ResponseQueue,
    call_count: usize = 0,

    fn publisher(broadcaster: *Broadcaster) show_notification_commands.NotificationPublisher {
        return .{ .context = broadcaster, .publish_fn = publish };
    }

    fn publish(context: *anyopaque, notification: schema.Notification) u8 {
        const broadcaster: *Broadcaster = @ptrCast(@alignCast(context));
        const pending = PendingNotification.init(notification);
        var delivered: u8 = 0;
        broadcaster.call_count += 1;

        for (broadcaster.recipients) |recipient| {
            if (recipient.pushNotification(pending)) {
                delivered += 1;
            }
        }

        return delivered;
    }
};

const PumpCapture = struct {
    count: usize = 0,

    fn delivery(capture: *PumpCapture) show_notification_controller.Delivery {
        return .{ .context = capture, .pump_all_fn = pumpAll };
    }

    fn pumpAll(context: *anyopaque) void {
        const capture: *PumpCapture = @ptrCast(@alignCast(context));
        capture.count += 1;
    }
};

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
    var broadcaster: Broadcaster = .{ .recipients = .{ &first, &saturated, &third } };
    var handler: show_notification_commands.ShowNotificationHandler = .{
        .notifications = broadcaster.publisher(),
    };
    var pump: PumpCapture = .{};
    var controller = show_notification_controller.Controller.init(
        &requester,
        handler.executor(),
        pump.delivery(),
    );
    var title = [_]u8{ 'B', 'u', 'i', 'l', 'd' };
    var message = [_]u8{ 'D', 'o', 'n', 'e' };
    const request_id: schema.RequestId = @enumFromInt(17);

    try controller.showNotification(.{
        .request_id = request_id,
        .notification = .{
            .level = .success,
            .duration_ms = 2500,
            .target = .{ .pane = try schema.id.pane(42) },
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
        try std.testing.expectEqual(schema.NotificationLevel.success, notification.level);
        try std.testing.expectEqual(@as(u32, 2500), notification.duration_ms);
        try std.testing.expectEqual(try schema.id.pane(42), notification.target.pane);
        try std.testing.expectEqualStrings("Build", notification.title);
        try std.testing.expectEqualStrings("Done", notification.message);
    }
}
