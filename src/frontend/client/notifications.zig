//! Connects notification use cases to the client timer infrastructure.

const notification_capability = @import("../notifications/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const notification_use_cases = client_application.notifications;

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

    try client.scheduleNotificationTick();
}
