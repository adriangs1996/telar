const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const ShowNotificationExecutorType = @import("../../application/commands/ShowNotificationExecutor.zig");
const Delivery = @import("Delivery.zig");
const ShowNotificationType = @import("telar-core").ShowNotification;
const Controller = @This();

responses: *ResponseQueueType,
show_notification: ShowNotificationExecutorType,
delivery: Delivery,

/// Creates one controller scoped to a notification request.
///
/// ```zig
/// var controller = Controller.init(&responses, handler.executor(), delivery);
/// ```
pub fn init(responses: *ResponseQueueType, show_notification: ShowNotificationExecutorType, delivery: Delivery) Controller {
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
pub fn showNotification(controller: *Controller, request: ShowNotificationType) !void {
    const confirmation = try controller.responses.reserveNotificationShown(request.request_id);
    const result = controller.show_notification.execute(.{
        .notification = request.notification,
    });

    confirmation.delivered_clients = result.delivered_clients;
    controller.delivery.pumpAll();
}
