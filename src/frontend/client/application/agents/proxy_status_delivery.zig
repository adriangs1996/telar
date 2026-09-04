//! Application policy for delivering one committed TLS interception state.

const std = @import("std");
const notification_capability = @import("../../../notifications/root.zig");
const client_model = @import("../../model/root.zig");

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

        const trust_only = commit.previous == commit.active and commit.previous_scope == commit.scope;
        try handler.effects.publish_notification(handler.effects.context, .{
            .level = if (commit.active or commit.system_trusted) .warning else .info,
            .title = if (trust_only)
                if (commit.system_trusted) "Proxy CA trusted by system" else "Proxy CA removed from system trust"
            else if (commit.active)
                "TLS interception active"
            else
                "TLS interception stopped",
            .message = if (trust_only)
                if (commit.system_trusted) "The short-lived Telar CA is installed" else "The Telar CA is no longer installed"
            else if (commit.active)
                "Agent network traffic is being observed"
            else
                "Agent network traffic is no longer observed",
            .duration_ns = if (commit.active or commit.system_trusted)
                7 * std.time.ns_per_s
            else
                notification_capability.default_duration_ns,
        });
    }

    fn validate(handler: *const DeliverProxyStatusHandler, commit: client_model.ProxyStatusCommit) !void {
        if (handler.model.proxyTlsActive() != commit.active or
            handler.model.proxyTlsScope() != commit.scope or
            handler.model.proxySystemTrusted() != commit.system_trusted or
            handler.model.version().proxy_status != commit.proxy_status_revision or
            (commit.previous == commit.active and commit.previous_scope == commit.scope and
                commit.previous_system_trusted == commit.system_trusted) or
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
            capture.model.proxyTlsScope() == capture.expected.scope and
            capture.model.proxySystemTrusted() == capture.expected.system_trusted and
            capture.model.version().proxy_status == capture.expected.proxy_status_revision and
            capture.expected.proxy_status_revision_before +% 1 == capture.expected.proxy_status_revision;
        capture.notification_valid = expectedNotification(capture.expected, input);

        if (capture.fail) {
            return error.NotificationPublicationFailed;
        }
    }
};

fn expectedNotification(commit: client_model.ProxyStatusCommit, input: notification_capability.Input) bool {
    const trust_only = commit.previous == commit.active and commit.previous_scope == commit.scope;
    if (trust_only) {
        if (commit.system_trusted) {
            return input.level == .warning and
                std.mem.eql(u8, input.title, "Proxy CA trusted by system") and
                std.mem.eql(u8, input.message, "The short-lived Telar CA is installed") and
                std.meta.activeTag(input.target) == .none and
                input.duration_ns == 7 * std.time.ns_per_s;
        }

        return input.level == .info and
            std.mem.eql(u8, input.title, "Proxy CA removed from system trust") and
            std.mem.eql(u8, input.message, "The Telar CA is no longer installed") and
            std.meta.activeTag(input.target) == .none and
            input.duration_ns == notification_capability.default_duration_ns;
    }

    if (commit.active) {
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
    const enabled = model.reconcileProxyStatus(.{ .active = true, .scope = .exact, .system_trusted = false }).?;
    var capture: Capture = .{ .model = &model, .expected = enabled };
    var use_case = deliveryHandler(&model, &capture);

    try use_case.execute(enabled);

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(capture.notification_valid);

    const disabled = model.reconcileProxyStatus(.{ .active = false, .scope = .exact, .system_trusted = false }).?;
    capture.expected = disabled;
    capture.notification_valid = false;
    try use_case.execute(disabled);

    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(capture.notification_valid);
}

test "DeliverProxyStatusHandler reports trust-only transitions" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const trusted = model.reconcileProxyStatus(.{ .active = false, .scope = .exact, .system_trusted = true }).?;
    var capture: Capture = .{ .model = &model, .expected = trusted };
    var use_case = deliveryHandler(&model, &capture);

    try use_case.execute(trusted);

    try std.testing.expect(capture.observed_commit);
    try std.testing.expect(capture.notification_valid);
}

test "DeliverProxyStatusHandler rejects stale transitions before publication" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const commit = model.reconcileProxyStatus(.{ .active = true, .scope = .wildcard, .system_trusted = false }).?;
    var capture: Capture = .{ .model = &model, .expected = commit };
    var use_case = deliveryHandler(&model, &capture);

    var altered = commit;
    altered.active = false;
    try std.testing.expectError(error.StaleProxyStatusCommit, use_case.execute(altered));
    altered = commit;
    altered.previous = true;
    altered.previous_scope = .wildcard;
    try std.testing.expectError(error.StaleProxyStatusCommit, use_case.execute(altered));
    altered = commit;
    altered.scope = .exact;
    try std.testing.expectError(error.StaleProxyStatusCommit, use_case.execute(altered));
    altered = commit;
    altered.proxy_status_revision_before -%= 1;
    try std.testing.expectError(error.StaleProxyStatusCommit, use_case.execute(altered));
    altered = commit;
    altered.proxy_status_revision -%= 1;
    try std.testing.expectError(error.StaleProxyStatusCommit, use_case.execute(altered));

    _ = model.reconcileProxyStatus(.{ .active = false, .scope = .exact, .system_trusted = false }).?;
    try std.testing.expectError(error.StaleProxyStatusCommit, use_case.execute(commit));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "DeliverProxyStatusHandler preserves the commit after publication failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const commit = model.reconcileProxyStatus(.{ .active = true, .scope = .exact, .system_trusted = false }).?;
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
