const Controller = @This();
const source_namespace = @import("show_notification.zig");
const show_notification_commands = @import("../../application/commands/show_notification.zig");
const Delivery = @import("Delivery.zig");
responses: *source_namespace.ResponseQueue,
show_notification: show_notification_commands.ShowNotificationExecutor,
delivery: Delivery,

/// Creates one controller scoped to a notification request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor(), delivery);
/// ```
pub fn init(responses: *source_namespace.ResponseQueue, show_notification: show_notification_commands.ShowNotificationExecutor, delivery: Delivery) Controller {
    return .{
        .responses = responses,
        .show_notification = show_notification,
        .delivery = delivery,
    };
}

/// Reserves the requester's exact confirmation before broadcasting. Queue
/// backpressure therefore causes no external effect. On success it commits
/// the accepted-recipient count and pumps every affected client once.
///
/// ```zig
/// try controller.showNotification(request);
/// ```
pub fn showNotification(controller: *Controller, request: source_namespace.schema.ShowNotification) !void {
    const confirmation = try controller.responses.reserveNotificationShown(request.request_id);
    const result = controller.show_notification.execute(.{
        .notification = request.notification,
    });

    confirmation.delivered_clients = result.delivered_clients;
    controller.delivery.pumpAll();
}
