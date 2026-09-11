//! Application use cases for the client notification lifecycle.

const std = @import("std");
const notification_capability = @import("../../root.zig").notifications;
const client_model = @import("../../root.zig").model;

pub const TimerEffects = @import("TimerEffects.zig");

pub const ActivationEffects = @import("ActivationEffects.zig");

pub const PublishCommand = @import("PublishCommand.zig");

pub const InteractionCommand = @import("InteractionCommand.zig");

pub const DeliveryReport = @import("DeliveryReport.zig");

pub const DeliveryOutcome = enum {
    delivered,
    undelivered,
};

pub const DeliveryEffects = @import("DeliveryEffects.zig");

pub const PublishNotificationHandler = @import("PublishNotificationHandler.zig");

pub const AdvanceNotificationsHandler = @import("AdvanceNotificationsHandler.zig");

pub const ActivateNotificationHandler = @import("ActivateNotificationHandler.zig");

pub const DismissNotificationHandler = @import("DismissNotificationHandler.zig");

pub const HandleNotificationDeliveryHandler = @import("HandleNotificationDeliveryHandler.zig");

const EffectsCapture = @import("NotificationsEffectsCapture.zig");

const DeliveryCapture = @import("DeliveryCapture.zig");

const NavigationCapture = @import("NavigationCapture.zig");

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
