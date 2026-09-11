const ModelType = @import("../../model/Model.zig");
const ProxyStatusCommitType = @import("../../model/ProxyStatusCommit.zig");
const ProxyStatusDeliveryEffects = @import("ProxyStatusDeliveryEffects.zig");
const InputType = @import("../../notifications/NotificationInput.zig");
const proxy_status_delivery = @import("proxy_status_delivery.zig");
const Capture = @This();

model: *const ModelType,
expected: ProxyStatusCommitType,
calls: usize = 0,
observed_commit: bool = false,
notification_valid: bool = false,
fail: bool = false,

pub fn effects(capture: *Capture) ProxyStatusDeliveryEffects {
    return .{ .context = capture, .publish_notification = publishNotification };
}

fn publishNotification(context: *anyopaque, input: InputType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.observed_commit = capture.model.proxyTlsActive() == capture.expected.active and
        capture.model.proxyTlsScope() == capture.expected.scope and
        capture.model.proxySystemTrusted() == capture.expected.system_trusted and
        capture.model.version().proxy_status == capture.expected.proxy_status_revision and
        capture.expected.proxy_status_revision_before +% 1 == capture.expected.proxy_status_revision;
    capture.notification_valid = proxy_status_delivery.expectedNotification(capture.expected, input);

    if (capture.fail) {
        return error.NotificationPublicationFailed;
    }
}
