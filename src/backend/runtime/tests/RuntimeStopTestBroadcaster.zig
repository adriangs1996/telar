const Recipient = @import("Recipient.zig");
const StopRequestedType = @import("../lifecycle/StopRequested.zig");
const NotificationsType = @import("../application/commands/Notifications.zig");
const Broadcaster = @This();

recipients: [3]*Recipient,
calls: usize = 0,
event: ?StopRequestedType = null,

pub fn notifications(broadcaster: *Broadcaster) NotificationsType {
    return .{ .context = broadcaster, .publish_fn = publish };
}

fn publish(context: *anyopaque, event: StopRequestedType) void {
    const broadcaster: *Broadcaster = @ptrCast(@alignCast(context));
    broadcaster.calls += 1;
    broadcaster.event = event;

    for (broadcaster.recipients) |recipient| {
        if (recipient.active) {
            recipient.delivery.requestStop();
        }
    }
}
