//! Runtime notifications operations, reached from requests.dispatch.

const core = @import("telar-core");
const Application = @import("../Application.zig");
const std = @import("std");
const StopRequestedType = @import("../../lifecycle/StopRequested.zig");
const RequestContext = @import("../RequestContext.zig");

/// Example: `try notifications.routeRuntimeStop(request);`.
pub fn routeRuntimeStop(request: *RequestContext) !void {
    const event = request.application.shutdown.request(request.session.key) orelse return;
    publishRuntimeStop(request.application, event);
}

/// Example: `try notifications.routeShowNotification(request, notification);`.
pub fn routeShowNotification(request: *RequestContext, notification: core.ShowNotification) !void {
    const confirmation = try request.session.delivery.responses.reserveNotificationShown(notification.request_id);
    confirmation.delivered_clients = request.application.publishNotification(notification.notification);
    request.application.pumpAll();
}

fn publishRuntimeStop(application: *Application, event: StopRequestedType) void {
    std.debug.assert(application.shutdown.isRequested());
    std.debug.assert(std.meta.eql(application.shutdown.initiator.?, event.initiator));

    for (&application.clients.items) |*slot| {
        const session = slot.* orelse continue;

        if (session.active()) {
            session.delivery.requestStop();
        }
    }
}
