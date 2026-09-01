//! Connects notification use cases to the client timer infrastructure.

const std = @import("std");
const core = @import("telar-core");
const input_capability = @import("../../../input/root.zig");
const notification_capability = @import("../../../notifications/root.zig");
const notifications_application = @import("../../application/notifications/root.zig");
const client_clock = @import("../../resources/clock.zig");
const client_model = @import("../../model/root.zig");
const notification_timers = @import("../../resources/notification_timers.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const tab_selections = @import("../tabs/tab_selections.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");

const presentation = @import("../../../presentation/root.zig");
const term = presentation.screen;
const Client = @import("../../client.zig");
const action = input_capability.action;
const notification_use_cases = notifications_application.notifications;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const schema = core.schema;

pub const DeliveryOutcome = notification_use_cases.DeliveryOutcome;

/// Delivers one bounded semantic notification through the runtime and records
/// the continuation consumed by its delivery report.
///
/// ```zig
/// const request_id = try requestDelivery(client, &notification);
/// ```
pub fn requestDelivery(client: *Client, notification: *const action.Notification) !schema.RequestId {
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliverNotification(client, .{
        .request_id = request_id,
        .notification = .{
            .level = notification.level,
            .duration_ms = notification.duration_ms,
            .target = notification.target,
            .title = notification.title(),
            .message = notification.message(),
        },
    });

    return request_id;
}

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

    const publication = try use_case.execute(.{ .now_ns = now_ns, .input = input });
    try deliverExternal(client, input);
    return publication;
}

/// Surfaces one published notice through the configured host channel. The
/// in-app center always shows it; `terminal` adds OSC 9 for the outer
/// terminal and `system` posts through the operating system on a worker.
fn deliverExternal(client: *Client, input: notification_capability.Input) !void {
    switch (client.notification_delivery) {
        .telar => {},
        .terminal => {
            const payload = notification_capability.host.Payload.init(input.title, input.message);
            try term.writeHostNotification(client.writer, payload.titleSlice(), payload.messageSlice());
            try client.writer.flush();
        },
        .system => {
            const payload = notification_capability.host.Payload.init(input.title, input.message);
            client.select.concurrent(.notified, notification_capability.host.notify, .{ client.io, payload }) catch {};
        },
    }
}

/// Publishes one local notice at the current client monotonic timestamp.
///
/// ```zig
/// try publishNow(client, input);
/// ```
pub fn publishNow(client: *Client, input: notification_capability.Input) !void {
    _ = try publish(client, client_clock.monotonic(client.io), input);
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

/// Activates one current notification identity and follows its target at most
/// once.
///
/// ```zig
/// const activation = try activate(client, id, now_ns) orelse return;
/// ```
pub fn activate(client: *Client, id: notification_capability.Id, now_ns: u64) !?client_model.NotificationActivation {
    var use_case: notification_use_cases.ActivateNotificationHandler = .{
        .model = &client.model,
        .effects = .{
            .timers = timerEffects(client),
            .context = client,
            .navigate = navigate,
        },
    };

    return use_case.execute(.{ .id = id, .now_ns = now_ns });
}

/// Activates one current notification and follows its target at the client
/// monotonic timestamp.
///
/// ```zig
/// _ = try activateNow(client, id);
/// ```
pub fn activateNow(client: *Client, id: notification_capability.Id) !?client_model.NotificationActivation {
    return activate(client, id, client_clock.monotonic(client.io));
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

/// Dismisses one current notification at the client monotonic timestamp.
///
/// ```zig
/// _ = try dismissNow(client, id);
/// ```
pub fn dismissNow(client: *Client, id: notification_capability.Id) !?client_model.NotificationChange {
    return dismiss(client, id, client_clock.monotonic(client.io));
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

fn navigate(context: *anyopaque, target: notification_capability.Target) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    switch (target) {
        .none => {},
        .select_tab => |tab_id| {
            var use_case = tab_selections.selectionHandler(client);

            _ = try use_case.execute(.{ .target = .{ .tab_id = tab_id } });
        },
        .select_workspace => |workspace| {
            _ = try workspace_handoffs.selectWorkspace(client, .{ .workspace = workspace });
        },
        .focus_pane => |pane_id| {
            var use_case = pane_focus.handler(client);

            _ = try use_case.execute(.{
                .target = .{ .pane_id = pane_id },
                .area = client.view.workbench(),
            });
        },
    }
}
