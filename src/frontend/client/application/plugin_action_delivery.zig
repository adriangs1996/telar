//! Application policy for delivering one classified plugin completion.

const std = @import("std");
const config = @import("../../config/root.zig");
const notification_capability = @import("../../notifications/root.zig");
const client_diagnostic = @import("client_diagnostic.zig");
const client_model = @import("../model.zig");
const plugin_action = @import("plugin_action.zig");

pub const Effects = struct {
    context: *anyopaque,
    publish_notification: *const fn (*anyopaque, notification_capability.Input) anyerror!void,
};

pub const DeliverPluginActionCompletionHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Maps one classified completion to a client-loop directive and commits
    /// failure diagnostics before publishing their bounded notification.
    ///
    /// ```zig
    /// const directive = try handler.execute(outcome);
    /// ```
    pub fn execute(handler: *DeliverPluginActionCompletionHandler, outcome: plugin_action.CompletionOutcome) !plugin_action.CompletionDirective {
        const failure = failurePublication(outcome) orelse return switch (outcome) {
            .exit => .exit_client,
            else => .continue_client,
        };

        var diagnostic_handler: client_diagnostic.ClientDiagnosticHandler = .{ .model = handler.model };
        _ = try diagnostic_handler.replace(.{ .diagnostic = failure.diagnostic });
        const message = handler.model.diagnostic() orelse return error.ClientDiagnosticMissing;
        try handler.effects.publish_notification(handler.effects.context, .{
            .level = .failure,
            .title = failure.title,
            .message = message,
            .duration_ns = 7 * std.time.ns_per_s,
        });

        return .continue_client;
    }
};

const FailurePublication = struct {
    diagnostic: config.Diagnostic,
    title: []const u8,
};

fn failurePublication(outcome: plugin_action.CompletionOutcome) ?FailurePublication {
    return switch (outcome) {
        .applied, .exit, .stale, .ignored => null,
        .worker_failed => |err| .{
            .diagnostic = client_diagnostic.formatted("plugin worker failed: {s}", .{@errorName(err)}),
            .title = "Plugin failed",
        },
        .authorization_failed => |err| if (err == error.PluginRegistryUnavailable) .{
            .diagnostic = client_diagnostic.formatted(
                "plugin registry changed while action was running",
                .{},
            ),
            .title = "Plugin failed",
        } else .{
            .diagnostic = client_diagnostic.formatted("plugin effect denied: {s}", .{@errorName(err)}),
            .title = "Plugin denied",
        },
    };
}

const Capture = struct {
    model: *const client_model.Model,
    calls: usize = 0,
    input: ?notification_capability.Input = null,
    observed_diagnostic: bool = false,
    fail: bool = false,

    fn effects(capture: *Capture) Effects {
        return .{ .context = capture, .publish_notification = publishNotification };
    }

    fn publishNotification(context: *anyopaque, input: notification_capability.Input) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.input = input;
        capture.observed_diagnostic = if (capture.model.diagnostic()) |diagnostic|
            std.mem.eql(u8, diagnostic, input.message)
        else
            false;

        if (capture.fail) {
            return error.NotificationPublicationFailed;
        }
    }
};

fn deliveryHandler(model: *client_model.Model, capture: *Capture) DeliverPluginActionCompletionHandler {
    return .{ .model = model, .effects = capture.effects() };
}

test "DeliverPluginActionCompletionHandler maps quiet outcomes to loop directives" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: Capture = .{ .model = &model };
    var handler = deliveryHandler(&model, &capture);

    try std.testing.expect(try handler.execute(.applied) == .continue_client);
    try std.testing.expect(try handler.execute(.stale) == .continue_client);
    try std.testing.expect(try handler.execute(.ignored) == .continue_client);
    try std.testing.expect(try handler.execute(.exit) == .exit_client);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}

test "DeliverPluginActionCompletionHandler owns worker and authorization diagnostics" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: Capture = .{ .model = &model };
    var handler = deliveryHandler(&model, &capture);

    _ = try handler.execute(.{ .worker_failed = error.PluginWorkerFailed });

    try std.testing.expectEqualStrings("plugin worker failed: PluginWorkerFailed", model.diagnostic().?);
    try std.testing.expectEqualStrings("Plugin failed", capture.input.?.title);
    try std.testing.expect(capture.observed_diagnostic);

    _ = try handler.execute(.{ .authorization_failed = error.PluginRegistryUnavailable });

    try std.testing.expectEqualStrings(
        "plugin registry changed while action was running",
        model.diagnostic().?,
    );
    try std.testing.expectEqualStrings("Plugin failed", capture.input.?.title);
    try std.testing.expect(capture.observed_diagnostic);

    _ = try handler.execute(.{ .authorization_failed = error.CapabilityDenied });

    try std.testing.expectEqualStrings("plugin effect denied: CapabilityDenied", model.diagnostic().?);
    try std.testing.expectEqualStrings("Plugin denied", capture.input.?.title);
    try std.testing.expectEqual(notification_capability.Level.failure, capture.input.?.level);
    try std.testing.expectEqual(@as(u64, 7 * std.time.ns_per_s), capture.input.?.duration_ns);
    try std.testing.expect(capture.observed_diagnostic);
    try std.testing.expectEqual(@as(usize, 3), capture.calls);
    try std.testing.expectEqual(client_model.Version{ .diagnostic = 3 }, model.version());
}

test "DeliverPluginActionCompletionHandler retains diagnostics after publication failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: Capture = .{ .model = &model, .fail = true };
    var handler = deliveryHandler(&model, &capture);

    try std.testing.expectError(
        error.NotificationPublicationFailed,
        handler.execute(.{ .worker_failed = error.PluginWorkerFailed }),
    );

    try std.testing.expect(capture.observed_diagnostic);
    try std.testing.expectEqualStrings("plugin worker failed: PluginWorkerFailed", model.diagnostic().?);
    try std.testing.expectEqual(client_model.Version{ .diagnostic = 1 }, model.version());
}
