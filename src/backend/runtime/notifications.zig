//! Notifications from clients, plugins or the runtime reach every active UI
//! client through its bounded notification lane.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const PendingNotification = @import("delivery/PendingNotification.zig");

/// Shows a client-requested notification and reports how many clients got it.
///
/// ```zig
/// try notifications.show(model, session, request);
/// ```
pub fn show(model: *RuntimeModel, session: *Session, request: core.ShowNotification) !void {
    const confirmation = try session.delivery.responses.reserveNotificationShown(request.request_id);
    confirmation.delivered_clients = publish(model, request.notification);
}

/// Queues a notification for active UI clients and returns how many took it.
///
/// ```zig
/// const recipients = notifications.publish(model, notification);
/// ```
pub fn publish(model: *RuntimeModel, notification: core.Notification) u8 {
    const pending = PendingNotification.init(notification);
    var delivered: u8 = 0;

    for (&model.clients.items) |*slot| {
        const recipient = slot.* orelse continue;

        if (!recipient.active() or recipient.role != .ui) {
            continue;
        }

        if (recipient.delivery.responses.pushNotification(pending)) {
            delivered += 1;
        }
    }

    return delivered;
}
