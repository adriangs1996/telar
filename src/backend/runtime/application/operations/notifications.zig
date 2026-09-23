//! Runtime notifications operations, reached from requests.dispatch.

const core = @import("telar-core");
const RuntimeModel = @import("../../RuntimeModel.zig");
const std = @import("std");
const StopRequestedType = @import("../../lifecycle/StopRequested.zig");
const RequestContext = @import("../RequestContext.zig");

/// Example: `try notifications.routeRuntimeStop(request);`.
pub fn routeRuntimeStop(request: *RequestContext) !void {
    const event = request.model.shutdown.request(request.session.key) orelse return;
    publishRuntimeStop(request.model, event);
}

/// Example: `try notifications.routeShowNotification(request, notification);`.
pub fn routeShowNotification(request: *RequestContext, notification: core.ShowNotification) !void {
    const confirmation = try request.session.delivery.responses.reserveNotificationShown(notification.request_id);
    confirmation.delivered_clients = request.model.publishNotification(notification.notification);
}

fn publishRuntimeStop(model: *RuntimeModel, event: StopRequestedType) void {
    std.debug.assert(model.shutdown.isRequested());
    std.debug.assert(std.meta.eql(model.shutdown.initiator.?, event.initiator));

    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;

        if (session.active()) {
            session.delivery.requestStop();
        }
    }
}
