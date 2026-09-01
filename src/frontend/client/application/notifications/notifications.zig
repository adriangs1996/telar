//! Application use cases for the client notification lifecycle.

const std = @import("std");
const notification_capability = @import("../../../notifications/root.zig");
const client_model = @import("../../model/root.zig");

pub const TimerEffects = struct {
    context: *anyopaque,
    reschedule: *const fn (*anyopaque) anyerror!void,
};

pub const ActivationEffects = struct {
    timers: TimerEffects,
    context: *anyopaque,
    navigate: *const fn (*anyopaque, notification_capability.Target) anyerror!void,
};

pub const PublishCommand = struct {
    now_ns: u64,
    input: notification_capability.Input,
};

pub const InteractionCommand = struct {
    id: notification_capability.Id,
    now_ns: u64,
};

pub const DeliveryReport = struct {
    delivered_clients: u8,
};

pub const DeliveryOutcome = enum {
    delivered,
    undelivered,
};

pub const DeliveryEffects = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, notification_capability.Input) anyerror!void,
};

pub const PublishNotificationHandler = struct {
    model: *client_model.Model,
    effects: TimerEffects,

    /// Commits owned notification state before rearming its lifecycle timer.
    ///
    /// ```zig
    /// const publication = try handler.execute(command);
    /// ```
    pub fn execute(handler: *PublishNotificationHandler, command: PublishCommand) !client_model.NotificationPublication {
        const publication = handler.model.publishNotification(command.now_ns, command.input);

        try handler.effects.reschedule(handler.effects.context);
        return publication;
    }
};

pub const AdvanceNotificationsHandler = struct {
    model: *client_model.Model,
    effects: TimerEffects,

    /// Advances every transition before scheduling the next useful deadline.
    ///
    /// ```zig
    /// _ = try handler.execute(now_ns);
    /// ```
    pub fn execute(handler: *AdvanceNotificationsHandler, now_ns: u64) !?client_model.NotificationChange {
        const change = handler.model.advanceNotifications(now_ns);

        try handler.effects.reschedule(handler.effects.context);
        return change;
    }
};

pub const ActivateNotificationHandler = struct {
    model: *client_model.Model,
    effects: ActivationEffects,

    /// Commits an exit transition, rearms time and then follows its target.
    ///
    /// ```zig
    /// const activation = try handler.execute(command) orelse return;
    /// ```
    pub fn execute(handler: *ActivateNotificationHandler, command: InteractionCommand) !?client_model.NotificationActivation {
        const activation = handler.model.activateNotification(command.id, command.now_ns) orelse return null;

        try handler.effects.timers.reschedule(handler.effects.timers.context);
        switch (activation.target) {
            .none => {},
            else => try handler.effects.navigate(handler.effects.context, activation.target),
        }
        return activation;
    }
};

pub const DismissNotificationHandler = struct {
    model: *client_model.Model,
    effects: TimerEffects,

    /// Commits an exit transition without activating the notification.
    ///
    /// ```zig
    /// const change = try handler.execute(command) orelse return;
    /// ```
    pub fn execute(handler: *DismissNotificationHandler, command: InteractionCommand) !?client_model.NotificationChange {
        const change = handler.model.dismissNotification(command.id, command.now_ns) orelse return null;

        try handler.effects.reschedule(handler.effects.context);
        return change;
    }
};

pub const HandleNotificationDeliveryHandler = struct {
    effects: DeliveryEffects,

    /// Publishes a local failure only when the runtime reached no clients.
    ///
    /// ```zig
    /// const outcome = try handler.execute(report);
    /// ```
    pub fn execute(handler: *HandleNotificationDeliveryHandler, report: DeliveryReport) !DeliveryOutcome {
        if (report.delivered_clients != 0) {
            return .delivered;
        }

        try handler.effects.publish(handler.effects.context, .{
            .level = .failure,
            .title = "Notification not delivered",
            .message = "No connected client could accept the notification",
        });

        return .undelivered;
    }
};

const EffectsCapture = struct {
    model: *const client_model.Model,
    expected_revision: u64 = 0,
    calls: usize = 0,
    observed_commit: bool = false,
    fail: bool = false,

    fn port(capture: *EffectsCapture) TimerEffects {
        return .{ .context = capture, .reschedule = reschedule };
    }

    fn reschedule(context: *anyopaque) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.observed_commit = capture.model.version().notifications == capture.expected_revision;

        if (capture.fail) {
            return error.TimerScheduleFailed;
        }
    }
};

const DeliveryCapture = struct {
    calls: usize = 0,
    input: ?notification_capability.Input = null,
    failure: ?anyerror = null,

    fn effects(capture: *DeliveryCapture) DeliveryEffects {
        return .{ .context = capture, .publish = publish };
    }

    fn publish(context: *anyopaque, input: notification_capability.Input) !void {
        const capture: *DeliveryCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.input = input;

        if (capture.failure) |failure| {
            return failure;
        }
    }
};

const NavigationCapture = struct {
    calls: usize = 0,
    target: ?notification_capability.Target = null,
    fail: bool = false,

    fn effects(capture: *NavigationCapture, timers: TimerEffects) ActivationEffects {
        return .{
            .timers = timers,
            .context = capture,
            .navigate = navigate,
        };
    }

    fn navigate(context: *anyopaque, target: notification_capability.Target) !void {
        const capture: *NavigationCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.target = target;

        if (capture.fail) {
            return error.NavigationFailed;
        }
    }
};

test "notification delivery publishes a failure only when every target rejected it" {
    var capture: DeliveryCapture = .{};
    var handler: HandleNotificationDeliveryHandler = .{ .effects = capture.effects() };

    try std.testing.expectEqual(DeliveryOutcome.delivered, try handler.execute(.{ .delivered_clients = 2 }));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);

    try std.testing.expectEqual(DeliveryOutcome.undelivered, try handler.execute(.{ .delivered_clients = 0 }));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(notification_capability.Level.failure, capture.input.?.level);
    try std.testing.expectEqualStrings("Notification not delivered", capture.input.?.title);
    try std.testing.expectEqualStrings(
        "No connected client could accept the notification",
        capture.input.?.message,
    );
}

test "notification delivery propagates publication failure" {
    var capture: DeliveryCapture = .{ .failure = error.PublicationFailed };
    var handler: HandleNotificationDeliveryHandler = .{ .effects = capture.effects() };

    try std.testing.expectError(error.PublicationFailed, handler.execute(.{ .delivered_clients = 0 }));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "notification handlers commit publication interaction and time before timer effects" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model, .expected_revision = 1 };
    const effects = capture.port();
    var publish: PublishNotificationHandler = .{ .model = &model, .effects = effects };

    const publication = try publish.execute(.{
        .now_ns = 0,
        .input = .{
            .title = "Ready",
            .message = "Open tab",
            .target = .{ .select_tab = @enumFromInt(7) },
        },
    });

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    capture.expected_revision = 2;
    var navigation: NavigationCapture = .{};
    var activate: ActivateNotificationHandler = .{
        .model = &model,
        .effects = navigation.effects(effects),
    };
    const activation = (try activate.execute(.{
        .id = publication.id,
        .now_ns = notification_capability.transition_duration_ns,
    })).?;

    try std.testing.expectEqual(client_model.Version{ .notifications = 2 }, model.version());
    try std.testing.expectEqual(@as(notification_capability.Target, .{ .select_tab = @enumFromInt(7) }), activation.target);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(@as(usize, 1), navigation.calls);
    try std.testing.expectEqualDeep(activation.target, navigation.target.?);
    try std.testing.expect((try activate.execute(.{
        .id = publication.id,
        .now_ns = notification_capability.transition_duration_ns,
    })) == null);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(@as(usize, 1), navigation.calls);

    capture.expected_revision = 3;
    var advance: AdvanceNotificationsHandler = .{ .model = &model, .effects = effects };
    _ = try advance.execute(notification_capability.transition_duration_ns * 2);

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 3), capture.calls);
    try std.testing.expect(!model.notificationSnapshot().hasItems());
}

test "notification publication remains committed after timer failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{
        .model = &model,
        .expected_revision = 1,
        .fail = true,
    };
    var handler: PublishNotificationHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.TimerScheduleFailed, handler.execute(.{
        .now_ns = 0,
        .input = .{ .title = "Failed", .message = "Timer unavailable" },
    }));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(client_model.Version{ .notifications = 1 }, model.version());
    try std.testing.expectEqualStrings("Failed", model.notificationSnapshot().itemAt(0).?.title());
}

test "notification activation preserves its commit and effect order on failure" {
    inline for (.{
        .{ .timer = true, .navigation = false, .navigation_calls = 0 },
        .{ .timer = false, .navigation = true, .navigation_calls = 1 },
    }) |scenario| {
        var model = client_model.Model.init(std.testing.allocator, true);
        defer model.deinit();
        const publication = model.publishNotification(0, .{
            .title = "Ready",
            .message = "Open pane",
            .target = .{ .focus_pane = @enumFromInt(7) },
        });
        var timers: EffectsCapture = .{
            .model = &model,
            .expected_revision = 2,
            .fail = scenario.timer,
        };
        var navigation: NavigationCapture = .{ .fail = scenario.navigation };
        var handler: ActivateNotificationHandler = .{
            .model = &model,
            .effects = navigation.effects(timers.port()),
        };

        const expected = if (scenario.timer) error.TimerScheduleFailed else error.NavigationFailed;
        try std.testing.expectError(expected, handler.execute(.{
            .id = publication.id,
            .now_ns = notification_capability.transition_duration_ns,
        }));

        try std.testing.expect(timers.observed_commit);
        try std.testing.expectEqual(client_model.Version{ .notifications = 2 }, model.version());
        try std.testing.expectEqual(@as(usize, 1), timers.calls);
        try std.testing.expectEqual(@as(usize, scenario.navigation_calls), navigation.calls);
    }
}

test "notification dismissal commits before its timer effect" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model, .expected_revision = 1 };
    const effects = capture.port();
    var publish: PublishNotificationHandler = .{ .model = &model, .effects = effects };
    const publication = try publish.execute(.{
        .now_ns = 0,
        .input = .{ .title = "Done", .message = "Dismiss me" },
    });

    capture.expected_revision = 2;
    var dismiss: DismissNotificationHandler = .{ .model = &model, .effects = effects };
    const change = (try dismiss.execute(.{
        .id = publication.id,
        .now_ns = notification_capability.transition_duration_ns,
    })).?;

    try std.testing.expectEqual(@as(u64, 2), change.notifications_revision);
    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expect((try dismiss.execute(.{
        .id = publication.id,
        .now_ns = notification_capability.transition_duration_ns,
    })) == null);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
}

test "notification advance rearms its timer without inventing a model change" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    _ = model.publishNotification(0, .{ .title = "Waiting", .message = "Not moving yet" });
    var capture: EffectsCapture = .{ .model = &model, .expected_revision = 1 };
    var advance: AdvanceNotificationsHandler = .{
        .model = &model,
        .effects = capture.port(),
    };

    try std.testing.expect((try advance.execute(0)) == null);

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(client_model.Version{ .notifications = 1 }, model.version());
}
