const ModelType = @import("../../model/Model.zig");
const ProxyStatusCommitType = @import("../../model/ProxyStatusCommit.zig");
const ProxyStatusDelivery = @import("ProxyStatusDelivery.zig");
const DeliveryCapture = @This();

model: *const ModelType,
calls: usize = 0,
observed_commit: bool = false,
commit: ?ProxyStatusCommitType = null,
fail: bool = false,

pub fn port(capture: *DeliveryCapture) ProxyStatusDelivery {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, commit: ProxyStatusCommitType) !void {
    const capture: *DeliveryCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.commit = commit;
    capture.observed_commit = capture.model.proxyTlsActive() == commit.active and
        capture.model.proxyTlsScope() == commit.scope and
        capture.model.proxySystemTrusted() == commit.system_trusted and
        capture.model.version().proxy_status == commit.proxy_status_revision and
        commit.proxy_status_revision_before +% 1 == commit.proxy_status_revision;

    if (capture.fail) {
        return error.ProxyStatusDeliveryFailed;
    }
}
