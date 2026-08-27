//! Runtime-control and cross-client notification entrypoints.

const core = @import("telar-core");
const common = @import("common.zig");

const schema = core.schema;

pub const Actions = struct {
    context: *anyopaque,
    publish_notification: *const fn (*anyopaque, schema.Notification) u8,
    pump_all: *const fn (*anyopaque) void,
    request_stop: *const fn (*anyopaque, common.ClientKey) void,
};

pub fn showNotification(
    responses: *common.ResponseQueue,
    actions: Actions,
    request: schema.ShowNotification,
) !void {
    try responses.push(.{ .notification_shown = .{
        .request_id = request.request_id,
        .delivered_clients = 0,
    } });
    const delivered = actions.publish_notification(actions.context, request.notification);
    responses.setNotificationDelivery(request.request_id, delivered);
    actions.pump_all(actions.context);
}

pub fn runtimeStop(client: common.ClientKey, actions: Actions) void {
    actions.request_stop(actions.context, client);
}
