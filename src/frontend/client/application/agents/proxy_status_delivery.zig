//! Application policy for delivering one committed TLS interception state.

const std = @import("std");
const notification_capability = @import("../../../notifications/root.zig");
const client_model = @import("../../model.zig");

pub const Effects = struct {
    context: *anyopaque,
    publish_notification: *const fn (*anyopaque, notification_capability.Input) anyerror!void,
};

pub const DeliverProxyStatusHandler = struct {
    model: *const client_model.Model,
    effects: Effects,

    /// Validates one exact proxy transition before publishing its semantic
    /// notification.
    ///
    /// ```zig
    /// try handler.execute(commit);
    /// ```
    pub fn execute(handler: *DeliverProxyStatusHandler, commit: client_model.ProxyStatusCommit) !void {
        try handler.validate(commit);

        try handler.effects.publish_notification(handler.effects.context, .{
            .level = if (commit.active) .warning else .info,
            .title = if (commit.active) "TLS interception active" else "TLS interception stopped",
            .message = if (commit.active)
                "Agent network traffic is being observed"
            else
                "Agent network traffic is no longer observed",
            .duration_ns = if (commit.active)
                7 * std.time.ns_per_s
            else
                notification_capability.default_duration_ns,
        });
    }

    fn validate(handler: *const DeliverProxyStatusHandler, commit: client_model.ProxyStatusCommit) !void {
        if (handler.model.proxyTlsActive() != commit.active or
            handler.model.version().proxy_status != commit.proxy_status_revision or
            commit.previous == commit.active or
            commit.proxy_status_revision_before +% 1 != commit.proxy_status_revision)
        {
            return error.StaleProxyStatusCommit;
        }
    }
};

const Capture = struct {
    model: *const client_model.Model,
    expected: client_model.ProxyStatusCommit,
    calls: usize = 0,
    observed_commit: bool = false,
    notification_valid: bool = false,
    fail: bool = false,

    fn effects(capture: *Capture) Effects {
        return .{ .context = capture, .publish_notification = publishNotification };
    }

    fn publishNotification(context: *anyopaque, input: notification_capability.Input) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.observed_commit = capture.model.proxyTlsActive() == capture.expected.active and
            capture.model.version().proxy_status == capture.expected.proxy_status_revision and
            capture.expected.proxy_status_revision_before +% 1 == capture.expected.proxy_status_revision;
        capture.notification_valid = expectedNotification(capture.expected.active, input);

        if (capture.fail) {
            return error.NotificationPublicationFailed;
        }
    }
};

fn expectedNotification(active: bool, input: notification_capability.Input) bool {
    if (active) {
        return input.level == .warning and
            std.mem.eql(u8, input.title, "TLS interception active") and
            std.mem.eql(u8, input.message, "Agent network traffic is being observed") and
            std.meta.activeTag(input.target) == .none and
            input.duration_ns == 7 * std.time.ns_per_s;
    }

    return input.level == .info and
        std.mem.eql(u8, input.title, "TLS interception stopped") and
        std.mem.eql(u8, input.message, "Agent network traffic is no longer observed") and
        std.meta.activeTag(input.target) == .none and
        input.duration_ns == notification_capability.default_duration_ns;
}

fn deliveryHandler(model: *const client_model.Model, capture: *Capture) DeliverProxyStatusHandler {
    return .{ .model = model, .effects = capture.effects() };
}

test "DeliverProxyStatusHandler publishes exact enabled and disabled notifications" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const enabled = model.reconcileProxyStatus(true).?;
    var capture: Capture = .{ .model = &model, .expected = enabled };
    var use_case = deliveryHandler(&model, &capture);

    try use_case.execute(enabled);

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(capture.notification_valid);

    const disabled = model.reconcileProxyStatus(false).?;
    capture.expected = disabled;
    capture.notification_valid = false;
    try use_case.execute(disabled);

    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(capture.notification_valid);
}

test "DeliverProxyStatusHandler rejects stale transitions before publication" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const commit = model.reconcileProxyStatus(true).?;
    var capture: Capture = .{ .model = &model, .expected = commit };
    var use_case = deliveryHandler(&model, &capture);

    var altered = commit;
    altered.active = false;
    try std.testing.expectError(error.StaleProxyStatusCommit, use_case.execute(altered));
    altered = commit;
    altered.previous = true;
    try std.testing.expectError(error.StaleProxyStatusCommit, use_case.execute(altered));
    altered = commit;
    altered.proxy_status_revision_before -%= 1;
    try std.testing.expectError(error.StaleProxyStatusCommit, use_case.execute(altered));
    altered = commit;
    altered.proxy_status_revision -%= 1;
    try std.testing.expectError(error.StaleProxyStatusCommit, use_case.execute(altered));

    _ = model.reconcileProxyStatus(false).?;
    try std.testing.expectError(error.StaleProxyStatusCommit, use_case.execute(commit));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "DeliverProxyStatusHandler preserves the commit after publication failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const commit = model.reconcileProxyStatus(true).?;
    var capture: Capture = .{
        .model = &model,
        .expected = commit,
        .fail = true,
    };
    var use_case = deliveryHandler(&model, &capture);

    try std.testing.expectError(error.NotificationPublicationFailed, use_case.execute(commit));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(capture.notification_valid);
    try std.testing.expect(model.proxyTlsActive());
    try std.testing.expectEqual(client_model.Version{ .proxy_status = 1 }, model.version());
}
