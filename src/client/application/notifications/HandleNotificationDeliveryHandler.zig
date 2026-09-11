const DeliveryEffects = @import("DeliveryEffects.zig");
const DeliveryReport = @import("DeliveryReport.zig");
const notifications = @import("notifications.zig");
const HandleNotificationDeliveryHandler = @This();

effects: DeliveryEffects,

/// Publishes a local failure only when the runtime reached no clients.
///
/// ```zig
/// const outcome = try handler.execute(report);
/// ```
pub fn execute(handler: *HandleNotificationDeliveryHandler, report: DeliveryReport) !notifications.DeliveryOutcome {
    if (report.delivered_clients != 0) {
        return .delivered;
    }

    try handler.effects.publish(handler.effects.context, .{
        .level = .failure,
        .title = "Notification not delivered",
        .message = "No connected client could accept the notification",
    });

    return .undelivered;
}
