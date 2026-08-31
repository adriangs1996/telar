//! Connects notification use cases to the client timer infrastructure.

const std = @import("std");
const core = @import("telar-core");
const notification_capability = @import("../notifications/root.zig");
const client_application = @import("application/root.zig");
const client_clock = @import("clock.zig");
const client_model = @import("model.zig");
const notification_timers = @import("notification_timers.zig");

const Client = @import("client.zig");
const notification_use_cases = client_application.notifications;
const request_lifecycle = @import("request_lifecycle.zig");
const schema = core.schema;

pub const DeliveryOutcome = notification_use_cases.DeliveryOutcome;

/// Consumes one correlated runtime delivery report and applies its policy.
///
/// ```zig
/// const outcome = try applyDeliveryReport(client, shown);
/// ```
pub fn applyDeliveryReport(client: *Client, shown: schema.NotificationShown) !DeliveryOutcome {
    const continuation = request_lifecycle.consume(client, shown.request_id) orelse
        return error.UnexpectedNotificationReply;
    if (continuation != .notification) {
        return error.UnexpectedNotificationReply;
    }

    var use_case: notification_use_cases.HandleNotificationDeliveryHandler = .{
        .effects = .{
            .context = client,
            .publish = publishDeliveryNotification,
        },
    };

    return use_case.execute(.{ .delivered_clients = shown.delivered_clients });
}

/// Translates and publishes one notification pushed by the runtime.
///
/// ```zig
/// const publication = try applyRuntime(client, notification);
/// ```
pub fn applyRuntime(client: *Client, notification: schema.Notification) !client_model.NotificationPublication {
    return publish(client, client_clock.monotonic(client.io), .{
        .level = switch (notification.level) {
            .info => .info,
            .success => .success,
            .warning => .warning,
            .failure => .failure,
        },
        .title = notification.title,
        .message = notification.message,
        .target = switch (notification.target) {
            .none => .none,
            .pane => |pane_id| .{ .focus_pane = pane_id },
            .tab => |tab_id| .{ .select_tab = tab_id },
            .workspace => |workspace_id| .{ .select_workspace = workspace_id },
        },
        .duration_ns = @as(u64, notification.duration_ms) * std.time.ns_per_ms,
    });
}

/// Publishes one owned notice through the application boundary.
///
/// ```zig
/// const publication = try publish(client, now_ns, input);
/// ```
pub fn publish(client: *Client, now_ns: u64, input: notification_capability.Input) !client_model.NotificationPublication {
    var use_case: notification_use_cases.PublishNotificationHandler = .{
        .model = &client.model,
        .effects = timerEffects(client),
    };

    return use_case.execute(.{ .now_ns = now_ns, .input = input });
}

/// Publishes one local notice at the current client monotonic timestamp.
///
/// ```zig
/// try publishNow(client, input);
/// ```
pub fn publishNow(client: *Client, input: notification_capability.Input) !void {
    _ = try publish(client, client_clock.monotonic(client.io), input);
}

/// Publishes the model's current diagnostic as one bounded failure notice.
///
/// ```zig
/// try publishDiagnostic(client, "Configuration rejected");
/// ```
pub fn publishDiagnostic(client: *Client, title: []const u8) !void {
    const message = client.model.diagnostic() orelse return error.ClientDiagnosticMissing;

    try publishNow(client, .{
        .level = .failure,
        .title = title,
        .message = message,
        .duration_ns = 7 * std.time.ns_per_s,
    });
}

/// Advances every notification lifecycle to one monotonic timestamp.
///
/// ```zig
/// _ = try advance(client, now_ns);
/// ```
pub fn advance(client: *Client, now_ns: u64) !?client_model.NotificationChange {
    var use_case: notification_use_cases.AdvanceNotificationsHandler = .{
        .model = &client.model,
        .effects = timerEffects(client),
    };

    return use_case.execute(now_ns);
}

/// Completes one physical timer before advancing and rearming notification
/// state through the application handler.
///
/// ```zig
/// _ = try handleTick(client, result);
/// ```
pub fn handleTick(client: *Client, result: anyerror!void) !?client_model.NotificationChange {
    try notification_timers.complete(client, result);

    return advance(client, client_clock.monotonic(client.io));
}

/// Activates one current notification identity at most once.
///
/// ```zig
/// const activation = try activate(client, id, now_ns) orelse return;
/// ```
pub fn activate(client: *Client, id: notification_capability.Id, now_ns: u64) !?client_model.NotificationActivation {
    var use_case: notification_use_cases.ActivateNotificationHandler = .{
        .model = &client.model,
        .effects = timerEffects(client),
    };

    return use_case.execute(.{ .id = id, .now_ns = now_ns });
}

/// Dismisses one current notification identity without navigation.
///
/// ```zig
/// _ = try dismiss(client, id, now_ns);
/// ```
pub fn dismiss(client: *Client, id: notification_capability.Id, now_ns: u64) !?client_model.NotificationChange {
    var use_case: notification_use_cases.DismissNotificationHandler = .{
        .model = &client.model,
        .effects = timerEffects(client),
    };

    return use_case.execute(.{ .id = id, .now_ns = now_ns });
}

fn timerEffects(client: *Client) notification_use_cases.TimerEffects {
    return .{ .context = client, .reschedule = reschedule };
}

fn reschedule(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try notification_timers.reschedule(client);
}

fn publishDeliveryNotification(context: *anyopaque, input: notification_capability.Input) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try publishNow(client, input);
}
