//! Connects notification use cases to the client timer infrastructure.

const Client = @import("../../Client.zig");
const NotificationType = @import("telar-client").Notification;
const RequestIdType = @import("telar-core").RequestId;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const NotificationShownType = @import("telar-core").NotificationShown;
const DeliveryOutcome = @import("telar-client").DeliveryOutcome;
const HandleNotificationDeliveryHandlerType = @import("telar-client").HandleNotificationDeliveryHandler;
const CoreNotification = @import("telar-core").Notification;
const NotificationPublicationType = @import("telar-client").NotificationPublication;
const monotonic_module = @import("telar-client").monotonic;
const std = @import("std");
const InputType = @import("telar-client").NotificationInput;
const PublishNotificationHandlerType = @import("telar-client").PublishNotificationHandler;
const PayloadType = @import("../../../notifications/Payload.zig");
const term = @import("../../../presentation/screen_support.zig");
const host_module = @import("../../../notifications/host.zig");
const NotificationChangeType = @import("telar-client").NotificationChange;
const AdvanceNotificationsHandlerType = @import("telar-client").AdvanceNotificationsHandler;
const notification_timers = @import("../../resources/notification_timers.zig");
const IdType = @import("telar-client").Id;
const NotificationActivationType = @import("telar-client").NotificationActivation;
const ActivateNotificationHandlerType = @import("telar-client").ActivateNotificationHandler;
const DismissNotificationHandlerType = @import("telar-client").DismissNotificationHandler;
const TimerEffectsType = @import("telar-client").TimerEffects;
const NotificationsRootTarget = @import("telar-client").NotificationTarget;
const tab_selections = @import("../tabs/tab_selections.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");
const pane_focus = @import("../panes/pane_focus.zig");

/// Delivers one bounded semantic notification through the runtime and records
/// the continuation consumed by its delivery report.
///
/// ```zig
/// const request_id = try requestDelivery(client, &notification);
/// ```
pub fn requestDelivery(client: *Client, notification: *const NotificationType) !RequestIdType {
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
pub fn applyDeliveryReport(client: *Client, shown: NotificationShownType) !DeliveryOutcome {
    const continuation = request_lifecycle.consume(client, shown.request_id) orelse
        return error.UnexpectedNotificationReply;
    if (continuation != .notification) {
        return error.UnexpectedNotificationReply;
    }

    var use_case: HandleNotificationDeliveryHandlerType = .{
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
pub fn applyRuntime(client: *Client, notification: CoreNotification) !NotificationPublicationType {
    return publish(client, monotonic_module(client.io), .{
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
pub fn publish(client: *Client, now_ns: u64, input: InputType) !NotificationPublicationType {
    var use_case: PublishNotificationHandlerType = .{
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
fn deliverExternal(client: *Client, input: InputType) !void {
    switch (client.notification_delivery) {
        .telar => {},
        .terminal => {
            const payload = PayloadType.init(input.title, input.message);
            try term.writeHostNotification(client.writer, payload.titleSlice(), payload.messageSlice());
            try client.writer.flush();
        },
        .system => {
            const payload = PayloadType.init(input.title, input.message);
            client.select.concurrent(.notified, host_module.notify, .{ client.io, payload }) catch {};
        },
    }
}

/// Publishes one local notice at the current client monotonic timestamp.
///
/// ```zig
/// try publishNow(client, input);
/// ```
pub fn publishNow(client: *Client, input: InputType) !void {
    _ = try publish(client, monotonic_module(client.io), input);
}

/// Advances every notification lifecycle to one monotonic timestamp.
///
/// ```zig
/// _ = try advance(client, now_ns);
/// ```
pub fn advance(client: *Client, now_ns: u64) !?NotificationChangeType {
    var use_case: AdvanceNotificationsHandlerType = .{
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
pub fn handleTick(client: *Client, result: anyerror!void) !?NotificationChangeType {
    try notification_timers.complete(client, result);

    return advance(client, monotonic_module(client.io));
}

/// Activates one current notification identity and follows its target at most
/// once.
///
/// ```zig
/// const activation = try activate(client, id, now_ns) orelse return;
/// ```
pub fn activate(client: *Client, id: IdType, now_ns: u64) !?NotificationActivationType {
    var use_case: ActivateNotificationHandlerType = .{
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
pub fn activateNow(client: *Client, id: IdType) !?NotificationActivationType {
    return activate(client, id, monotonic_module(client.io));
}

/// Dismisses one current notification identity without navigation.
///
/// ```zig
/// _ = try dismiss(client, id, now_ns);
/// ```
pub fn dismiss(client: *Client, id: IdType, now_ns: u64) !?NotificationChangeType {
    var use_case: DismissNotificationHandlerType = .{
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
pub fn dismissNow(client: *Client, id: IdType) !?NotificationChangeType {
    return dismiss(client, id, monotonic_module(client.io));
}

fn timerEffects(client: *Client) TimerEffectsType {
    return .{ .context = client, .reschedule = reschedule };
}

fn reschedule(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try notification_timers.reschedule(client);
}

fn publishDeliveryNotification(context: *anyopaque, input: InputType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try publishNow(client, input);
}

fn navigate(context: *anyopaque, target: NotificationsRootTarget) !void {
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
                .area = client.geometry().area,
            });
        },
    }
}
