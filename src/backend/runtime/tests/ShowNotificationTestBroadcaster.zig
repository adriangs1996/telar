const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const NotificationPublisherType = @import("../application/commands/NotificationPublisher.zig");
const NotificationType = @import("telar-core").Notification;
const PendingNotificationType = @import("../delivery/PendingNotification.zig");
const Broadcaster = @This();

recipients: [3]*ResponseQueueType,
call_count: usize = 0,

pub fn publisher(broadcaster: *Broadcaster) NotificationPublisherType {
    return .{ .context = broadcaster, .publish_fn = publish };
}

fn publish(context: *anyopaque, notification: NotificationType) u8 {
    const broadcaster: *Broadcaster = @ptrCast(@alignCast(context));
    const pending = PendingNotificationType.init(notification);
    var delivered: u8 = 0;
    broadcaster.call_count += 1;

    for (broadcaster.recipients) |recipient| {
        if (recipient.pushNotification(pending)) {
            delivered += 1;
        }
    }

    return delivered;
}
