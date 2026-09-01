//! Application use case for reconciling runtime TLS interception state.

const std = @import("std");
const client_model = @import("../../model/root.zig");

pub const ProxyStatusDelivery = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, client_model.ProxyStatusCommit) anyerror!void,
};

pub const ApplyProxyStatusHandler = struct {
    model: *client_model.Model,
    delivery: ProxyStatusDelivery,

    /// Commits a changed proxy state before delivering its exact transition.
    /// Repeated values produce neither a commit nor a delivery.
    ///
    /// ```zig
    /// const commit = try handler.execute(true) orelse return;
    /// ```
    pub fn execute(handler: *ApplyProxyStatusHandler, active: bool) !?client_model.ProxyStatusCommit {
        const commit = handler.model.reconcileProxyStatus(active) orelse return null;

        try handler.delivery.deliver(handler.delivery.context, commit);
        return commit;
    }
};

const DeliveryCapture = struct {
    model: *const client_model.Model,
    calls: usize = 0,
    observed_commit: bool = false,
    commit: ?client_model.ProxyStatusCommit = null,
    fail: bool = false,

    fn port(capture: *DeliveryCapture) ProxyStatusDelivery {
        return .{ .context = capture, .deliver = deliver };
    }

    fn deliver(context: *anyopaque, commit: client_model.ProxyStatusCommit) !void {
        const capture: *DeliveryCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.commit = commit;
        capture.observed_commit = capture.model.proxyTlsActive() == commit.active and
            capture.model.version().proxy_status == commit.proxy_status_revision and
            commit.proxy_status_revision_before +% 1 == commit.proxy_status_revision;

        if (capture.fail) {
            return error.ProxyStatusDeliveryFailed;
        }
    }
};

test "ApplyProxyStatusHandler commits before delivering each changed state" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: DeliveryCapture = .{ .model = &model };
    var handler: ApplyProxyStatusHandler = .{
        .model = &model,
        .delivery = capture.port(),
    };

    try std.testing.expect((try handler.execute(false)) == null);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);

    const enabled = (try handler.execute(true)).?;

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqualDeep(enabled, capture.commit.?);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect((try handler.execute(true)) == null);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    const disabled = (try handler.execute(false)).?;

    try std.testing.expect(!disabled.active);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(client_model.Version{ .proxy_status = 2 }, model.version());
}

test "ApplyProxyStatusHandler preserves a commit after delivery failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: DeliveryCapture = .{ .model = &model, .fail = true };
    var handler: ApplyProxyStatusHandler = .{
        .model = &model,
        .delivery = capture.port(),
    };

    try std.testing.expectError(error.ProxyStatusDeliveryFailed, handler.execute(true));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(model.proxyTlsActive());
    try std.testing.expectEqual(client_model.Version{ .proxy_status = 1 }, model.version());
}
