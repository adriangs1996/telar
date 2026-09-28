//! Notifications: publishes, times, activates and dismisses notifications and
//! delivers them to the host.
const pacing = @import("pacing");
const data = @import("model");
const link_opening = @import("../links/link_opening.zig");
const core = @import("telar-core");
const std = @import("std");
const pane_focus = @import("../panes/pane_focus.zig");
const tab_selection = @import("../workspace/tab_selection.zig");
const workspace_handoff = @import("../workspace/workspace_handoff.zig");
const Client = @import("../execution/Client.zig");

/// Publishes one owned notice through the application boundary.
/// Example: `_ = try notifications.publishNotification(client, now_ns, input);`
pub fn publishNotification(client: *Client, now_ns: u64, input: data.NotificationInput) !data.NotificationPublication {
    const publication = data.notifications.publish(&client.model, now_ns, input);
    try scheduleNotificationTimer(client);
    try deliverHostNotification(client, input);
    return publication;
}

/// Publishes one local notice at the current client monotonic timestamp.
/// Example: `try notifications.publishNotificationNow(client, input);`
pub fn publishNotificationNow(client: *Client, input: data.NotificationInput) !void {
    _ = try publishNotification(client, pacing.clock.monotonic(client.io), input);
}

/// Completes one physical timer before advancing and rearming notification
/// state in the client model.
/// Example: `_ = try notifications.completeNotificationTick(client, result);`
pub fn completeNotificationTick(client: *Client, result: anyerror!void) !?data.NotificationChange {
    try client.model.notification_scheduler.complete(result);

    return advanceNotifications(client, pacing.clock.monotonic(client.io));
}

/// Activates one current notification and follows its target at the client
/// monotonic timestamp.
/// Example: `_ = try notifications.activateNotificationNow(client, id);`
pub fn activateNotificationNow(client: *Client, id: data.NotificationId) !?data.NotificationActivation {
    return activateNotification(client, id, pacing.clock.monotonic(client.io));
}

/// Dismisses one current notification at the client monotonic timestamp.
/// Example: `_ = try notifications.dismissNotificationNow(client, id);`
pub fn dismissNotificationNow(client: *Client, id: data.NotificationId) !?data.NotificationChange {
    return dismissNotification(client, id, pacing.clock.monotonic(client.io));
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try notifications.sendNotificationRequest(client, request);`
fn sendNotificationRequest(model: *data.ClientModel, request: core.ShowNotification) !void {
    try model.request_lifecycle.tracker.add(request.request_id, .notification);
    errdefer _ = model.request_lifecycle.tracker.take(request.request_id);
    try model.to_runtime.pushNotification(request);
}

/// Delivers one bounded semantic notification through the runtime and records
/// the continuation consumed by its delivery report.
pub fn requestNotificationDelivery(model: *data.ClientModel, notification: *const data.Notification) !core.RequestId {
    const request_id = try model.request_lifecycle.nextId();
    try sendNotificationRequest(
        model,
        .{
            .request_id = request_id,
            .notification = .{
                .level = notification.level,
                .duration_ms = notification.duration_ms,
                .target = notification.target,
                .title = notification.title(),
                .message = notification.message(),
            },
        },
    );

    return request_id;
}

/// Consumes one correlated runtime delivery report and applies its policy.
pub fn completeNotificationDelivery(client: *Client, shown: core.NotificationShown) !NotificationDeliveryOutcome {
    const continuation = client.model.request_lifecycle.tracker.take(shown.request_id) orelse
        return error.UnexpectedNotificationReply;
    if (continuation != .notification) {
        return error.UnexpectedNotificationReply;
    }

    if (shown.delivered_clients != 0) {
        return .delivered;
    }

    try publishNotificationNow(
        client,
        .{
            .level = .failure,
            .title = "Notification not delivered",
            .message = "No connected client could accept the notification",
        },
    );
    return .undelivered;
}

/// Translates and publishes one notification pushed by the runtime.
pub fn applyRuntimeNotification(client: *Client, notification: core.Notification) !data.NotificationPublication {
    return publishNotification(
        client,
        pacing.clock.monotonic(client.io),
        .{
            .level = switch (notification.level) {
                .info => .info,
                .success => .success,
                .warning => .warning,
                .failure => .failure,
            },
            .title = notification.title,
            .message = notification.message,
            .link = notification.link,
            .target = switch (notification.target) {
                .none => .none,
                .pane => |pane_id| .{
                    .focus_pane = pane_id,
                },
                .tab => |tab_id| .{
                    .select_tab = tab_id,
                },
                .workspace => |workspace_id| .{
                    .select_workspace = workspace_id,
                },
            },
            .duration_ns = @as(u64, notification.duration_ms) * std.time.ns_per_ms,
        },
    );
}

/// Surfaces one published notice through the configured host channel. The
/// in-app center always shows it; `system` also posts it to the desktop.
fn deliverHostNotification(client: *Client, input: data.NotificationInput) !void {
    if (client.model.config.notification_delivery == .telar) {
        return;
    }

    const payload: data.NotificationPayload = .init(input.title, input.message);
    switch (client.model.config.notification_delivery) {
        .telar => unreachable,
        // A system notice is best effort; a saturated inbox drops it.
        .system => client.to_background.push(.{ .system_notification = payload }) catch {},
    }
}

/// Advances every notification lifecycle to one monotonic timestamp.
fn advanceNotifications(client: *Client, now_ns: u64) !?data.NotificationChange {
    const change = data.notifications.advance(&client.model, now_ns);
    try scheduleNotificationTimer(client);
    return change;
}

/// Activates one current notification identity and follows its target at most
/// once.
fn activateNotification(client: *Client, id: data.NotificationId, now_ns: u64) !?data.NotificationActivation {
    // The link is copied before activation starts the card's exit.
    const link = linkOf(client, id);
    const activation = data.notifications.activate(&client.model, id, now_ns) orelse return null;
    try scheduleNotificationTimer(client);
    try navigateNotification(client, activation.target);
    if (link) |target| {
        _ = try link_opening.openLink(client, target, null);
    }

    return activation;
}

// The link a notification carries, through the same classification every
// opened link passes; null when it has none.
fn linkOf(client: *Client, id: data.NotificationId) ?data.LinkTarget {
    const item = client.model.notification_center.find(id) orelse return null;
    if (item.link_len == 0) {
        return null;
    }

    return data.LinkTarget.init(item.link()) catch null;
}

/// Dismisses one current notification identity without navigation.
fn dismissNotification(client: *Client, id: data.NotificationId, now_ns: u64) !?data.NotificationChange {
    const change = data.notifications.dismiss(&client.model, id, now_ns) orelse return null;
    try scheduleNotificationTimer(client);
    return change;
}

fn navigateNotification(client: *Client, target: data.NotificationTarget) !void {
    switch (target) {
        .none => {},
        .select_tab => |tab_id| {
            _ = try tab_selection.selectTab(
                client,
                .{
                    .target = .{
                        .tab_id = tab_id,
                    },
                },
            );
        },
        .select_workspace => |workspace| {
            _ = try workspace_handoff.selectWorkspace(
                client,
                .{
                    .workspace = workspace,
                },
            );
        },
        .focus_pane => |pane_id| {
            _ = try pane_focus.applyPaneFocus(
                client,
                .{
                    .target = .{
                        .pane_id = pane_id,
                    },
                    .area = client.geometry().area,
                },
            );
        },
    }
}

/// Replaces the pending deadline from current model state and starts at most
/// one inbox producer through the timer port.
fn scheduleNotificationTimer(client: *Client) !void {
    const scheduler = &client.model.notification_scheduler;
    const now_ns = pacing.clock.monotonic(client.io);
    const deadline_ns = client.model.notification_center.nextDeadline(
        now_ns,
        client.model.host.animation_frame_ns orelse std.math.maxInt(u64),
    );
    switch (scheduler.update(client.io, deadline_ns)) {
        .idle, .retained => {},
        .schedule => client.to_workers.push(.{ .timer = .{ .kind = .notification, .scheduler = scheduler } }) catch |err| {
            scheduler.schedulingFailed();

            return err;
        },
    }
}

const NotificationDeliveryOutcome = enum {
    delivered,
    undelivered,
};
