const Broadcaster = @This();
const source_namespace = @import("show_notification_test.zig");
const show_notification_commands = @import("../application/commands/show_notification.zig");
recipients: [3]*source_namespace.ResponseQueue,
call_count: usize = 0,

pub fn publisher(broadcaster: *Broadcaster) show_notification_commands.NotificationPublisher {
    return .{ .context = broadcaster, .publish_fn = publish };
}

fn publish(context: *anyopaque, notification: source_namespace.schema.Notification) u8 {
    const broadcaster: *Broadcaster = @ptrCast(@alignCast(context));
    const pending = source_namespace.PendingNotification.init(notification);
    var delivered: u8 = 0;
    broadcaster.call_count += 1;

    for (broadcaster.recipients) |recipient| {
        if (recipient.pushNotification(pending)) {
            delivered += 1;
        }
    }

    return delivered;
}
