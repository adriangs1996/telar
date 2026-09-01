//! Application policy for delivering one resolved configuration reload.

const std = @import("std");
const lua_config = @import("../../../config/root.zig");
const notification_capability = @import("../../../notifications/root.zig");
const client_diagnostic = @import("client_diagnostic.zig");
const client_model = @import("../../model/root.zig");

pub const Resolution = union(enum) {
    unchanged,
    rejected: lua_config.Diagnostic,
    adopted,
};

pub const Outcome = union(enum) {
    unchanged,
    rejected,
    adopted: client_model.ConfigurationCommit,
};

pub const Effects = struct {
    context: *anyopaque,
    apply_adoption: *const fn (*anyopaque) anyerror!client_model.ConfigurationCommit,
    publish_notification: *const fn (*anyopaque, notification_capability.Input) anyerror!void,
    rearm: *const fn (*anyopaque) anyerror!void,
};

pub const DeliverConfigReloadHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Delivers one resolved reload and rearms its watcher only after every
    /// outcome-specific effect has succeeded.
    ///
    /// ```zig
    /// const outcome = try handler.execute(resolution);
    /// ```
    pub fn execute(handler: *DeliverConfigReloadHandler, resolution: Resolution) !Outcome {
        const outcome: Outcome = switch (resolution) {
            .unchanged => .unchanged,
            .rejected => |diagnostic| try handler.deliverRejection(diagnostic),
            .adopted => try handler.deliverAdoption(),
        };

        try handler.effects.rearm(handler.effects.context);

        return outcome;
    }

    fn deliverRejection(handler: *DeliverConfigReloadHandler, diagnostic: lua_config.Diagnostic) !Outcome {
        var diagnostic_handler: client_diagnostic.ClientDiagnosticHandler = .{ .model = handler.model };
        _ = try diagnostic_handler.replace(.{
            .diagnostic = diagnostic,
            .invalid_fallback = client_diagnostic.formatted(
                "configuration reload failed: invalid diagnostic text",
                .{},
            ),
        });
        const message = handler.model.diagnostic() orelse return error.ClientDiagnosticMissing;
        try handler.effects.publish_notification(handler.effects.context, .{
            .level = .failure,
            .title = "Configuration rejected",
            .message = message,
            .duration_ns = 7 * std.time.ns_per_s,
        });

        return .rejected;
    }

    fn deliverAdoption(handler: *DeliverConfigReloadHandler) !Outcome {
        const commit = try handler.effects.apply_adoption(handler.effects.context);
        try handler.effects.publish_notification(handler.effects.context, .{
            .level = .success,
            .title = "Configuration reloaded",
            .message = "The new settings are active",
        });

        return .{ .adopted = commit };
    }
};

const Event = enum {
    apply_adoption,
    publish_notification,
    rearm,
};

const Failure = enum {
    none,
    apply_adoption,
    publish_notification,
    rearm,
};

const Capture = struct {
    model: *const client_model.Model,
    events: [3]Event = undefined,
    event_count: usize = 0,
    notification: ?notification_capability.Input = null,
    diagnostic_observed: bool = false,
    failure: Failure = .none,

    fn effects(capture: *Capture) Effects {
        return .{
            .context = capture,
            .apply_adoption = applyAdoption,
            .publish_notification = publishNotification,
            .rearm = rearm,
        };
    }

    fn applyAdoption(raw_context: *anyopaque) !client_model.ConfigurationCommit {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.apply_adoption);

        if (capture.failure == .apply_adoption) {
            return error.ConfigurationAdoptionFailed;
        }

        return testingCommit();
    }

    fn publishNotification(raw_context: *anyopaque, input: notification_capability.Input) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.publish_notification);
        capture.notification = input;
        capture.diagnostic_observed = if (capture.model.diagnostic()) |diagnostic|
            std.mem.eql(u8, diagnostic, input.message)
        else
            false;

        if (capture.failure == .publish_notification) {
            return error.NotificationPublicationFailed;
        }
    }

    fn rearm(raw_context: *anyopaque) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.rearm);

        if (capture.failure == .rearm) {
            return error.ConfigReloadRearmFailed;
        }
    }

    fn record(capture: *Capture, event: Event) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn eventSlice(capture: *const Capture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

fn testingCommit() client_model.ConfigurationCommit {
    return .{
        .generation = 2,
        .configuration_revision = 1,
        .sidebar = null,
        .pane_gaps_changed = false,
        .panes_revision = 0,
    };
}

fn deliveryHandler(model: *client_model.Model, capture: *Capture) DeliverConfigReloadHandler {
    return .{ .model = model, .effects = capture.effects() };
}

fn makeDiagnostic(text: []const u8) lua_config.Diagnostic {
    var value: lua_config.Diagnostic = .{};
    value.set("{s}", .{text});

    return value;
}

fn invalidDiagnostic() lua_config.Diagnostic {
    var value: lua_config.Diagnostic = .{};
    value.buffer[0] = 0xff;
    value.len = 1;

    return value;
}

test "DeliverConfigReloadHandler rearms an unchanged reload without other effects" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: Capture = .{ .model = &model };
    var handler = deliveryHandler(&model, &capture);

    try std.testing.expect(try handler.execute(.unchanged) == .unchanged);

    try std.testing.expectEqualSlices(Event, &.{.rearm}, capture.eventSlice());
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "DeliverConfigReloadHandler commits a rejection before notifying and rearming" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: Capture = .{ .model = &model };
    var handler = deliveryHandler(&model, &capture);

    try std.testing.expect(try handler.execute(.{ .rejected = makeDiagnostic("invalid keymap") }) == .rejected);

    try std.testing.expectEqualSlices(
        Event,
        &.{ .publish_notification, .rearm },
        capture.eventSlice(),
    );
    try std.testing.expectEqualStrings("invalid keymap", model.diagnostic().?);
    try std.testing.expectEqual(notification_capability.Level.failure, capture.notification.?.level);
    try std.testing.expectEqualStrings("Configuration rejected", capture.notification.?.title);
    try std.testing.expectEqual(@as(u64, 7 * std.time.ns_per_s), capture.notification.?.duration_ns);
    try std.testing.expect(capture.diagnostic_observed);
    try std.testing.expectEqual(client_model.Version{ .diagnostic = 1 }, model.version());
}

test "DeliverConfigReloadHandler uses the explicit invalid diagnostic fallback" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: Capture = .{ .model = &model };
    var handler = deliveryHandler(&model, &capture);

    _ = try handler.execute(.{ .rejected = invalidDiagnostic() });

    try std.testing.expectEqualStrings(
        "configuration reload failed: invalid diagnostic text",
        model.diagnostic().?,
    );
    try std.testing.expect(capture.diagnostic_observed);
}

test "DeliverConfigReloadHandler publishes success after adoption and before rearming" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: Capture = .{ .model = &model };
    var handler = deliveryHandler(&model, &capture);

    const outcome = try handler.execute(.adopted);

    try std.testing.expectEqualDeep(testingCommit(), outcome.adopted);
    try std.testing.expectEqualSlices(
        Event,
        &.{ .apply_adoption, .publish_notification, .rearm },
        capture.eventSlice(),
    );
    try std.testing.expectEqual(notification_capability.Level.success, capture.notification.?.level);
    try std.testing.expectEqualStrings("Configuration reloaded", capture.notification.?.title);
    try std.testing.expectEqualStrings("The new settings are active", capture.notification.?.message);
    try std.testing.expect(!capture.diagnostic_observed);
}

test "DeliverConfigReloadHandler preserves each completed stage after failures" {
    const Scenario = struct {
        failure: Failure,
        expected_error: anyerror,
        expected_events: []const Event,
    };
    const scenarios = [_]Scenario{
        .{
            .failure = .apply_adoption,
            .expected_error = error.ConfigurationAdoptionFailed,
            .expected_events = &.{.apply_adoption},
        },
        .{
            .failure = .publish_notification,
            .expected_error = error.NotificationPublicationFailed,
            .expected_events = &.{ .apply_adoption, .publish_notification },
        },
        .{
            .failure = .rearm,
            .expected_error = error.ConfigReloadRearmFailed,
            .expected_events = &.{ .apply_adoption, .publish_notification, .rearm },
        },
    };

    for (scenarios) |scenario| {
        var model = client_model.Model.init(std.testing.allocator, true);
        defer model.deinit();
        var capture: Capture = .{ .model = &model, .failure = scenario.failure };
        var handler = deliveryHandler(&model, &capture);

        try std.testing.expectError(scenario.expected_error, handler.execute(.adopted));

        try std.testing.expectEqualSlices(Event, scenario.expected_events, capture.eventSlice());
    }
}

test "DeliverConfigReloadHandler retains a rejected diagnostic when notification fails" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: Capture = .{ .model = &model, .failure = .publish_notification };
    var handler = deliveryHandler(&model, &capture);

    try std.testing.expectError(
        error.NotificationPublicationFailed,
        handler.execute(.{ .rejected = makeDiagnostic("reload rejected") }),
    );

    try std.testing.expectEqualSlices(Event, &.{.publish_notification}, capture.eventSlice());
    try std.testing.expectEqualStrings("reload rejected", model.diagnostic().?);
    try std.testing.expect(capture.diagnostic_observed);
    try std.testing.expectEqual(client_model.Version{ .diagnostic = 1 }, model.version());
}
