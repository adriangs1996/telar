const Capture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("config_reload_delivery.zig");
const notification_capability = @import("../../root.zig").notifications;
const Effects = @import("ConfigReloadDeliveryEffects.zig");
const std = @import("std");
model: *const client_model.Model,
events: [3]source_namespace.Event = undefined,
event_count: usize = 0,
notification: ?notification_capability.Input = null,
diagnostic_observed: bool = false,
failure: source_namespace.Failure = .none,

pub fn effects(capture: *Capture) Effects {
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

    return source_namespace.testingCommit();
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

fn record(capture: *Capture, event: source_namespace.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
