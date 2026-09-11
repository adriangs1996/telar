//! Application policy for delivering one resolved configuration reload.

const std = @import("std");
const lua_config = @import("../../config/root.zig");
const notification_capability = @import("../../root.zig").notifications;
const client_diagnostic = @import("client_diagnostic.zig");
const client_model = @import("../../root.zig").model;

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

pub const Effects = @import("ConfigReloadDeliveryEffects.zig");

pub const DeliverConfigReloadHandler = @import("DeliverConfigReloadHandler.zig");

pub const Event = enum {
    apply_adoption,
    publish_notification,
    rearm,
};

pub const Failure = enum {
    none,
    apply_adoption,
    publish_notification,
    rearm,
};

const Capture = @import("Capture.zig");

pub fn testingCommit() client_model.ConfigurationCommit {
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
