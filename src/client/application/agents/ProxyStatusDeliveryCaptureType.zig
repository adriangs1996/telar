const Capture = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("ProxyStatusDeliveryEffects.zig");
const notification_capability = @import("../../root.zig").notifications;
const source_namespace = @import("proxy_status_delivery.zig");
model: *const client_model.Model,
expected: client_model.ProxyStatusCommit,
calls: usize = 0,
observed_commit: bool = false,
notification_valid: bool = false,
fail: bool = false,

pub fn effects(capture: *Capture) Effects {
    return .{ .context = capture, .publish_notification = publishNotification };
}

fn publishNotification(context: *anyopaque, input: notification_capability.Input) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.observed_commit = capture.model.proxyTlsActive() == capture.expected.active and
        capture.model.proxyTlsScope() == capture.expected.scope and
        capture.model.proxySystemTrusted() == capture.expected.system_trusted and
        capture.model.version().proxy_status == capture.expected.proxy_status_revision and
        capture.expected.proxy_status_revision_before +% 1 == capture.expected.proxy_status_revision;
    capture.notification_valid = source_namespace.expectedNotification(capture.expected, input);

    if (capture.fail) {
        return error.NotificationPublicationFailed;
    }
}
