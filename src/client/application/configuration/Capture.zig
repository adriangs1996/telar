const ModelType = @import("../../model/Model.zig");
const config_reload_delivery = @import("config_reload_delivery.zig");
const InputType = @import("../../notifications/NotificationInput.zig");
const ConfigReloadDeliveryEffects = @import("ConfigReloadDeliveryEffects.zig");
const ConfigurationCommitType = @import("../../model/ConfigurationCommit.zig");
const std = @import("std");
const Capture = @This();

model: *const ModelType,
events: [3]config_reload_delivery.Event = undefined,
event_count: usize = 0,
notification: ?InputType = null,
diagnostic_observed: bool = false,
failure: config_reload_delivery.Failure = .none,

pub fn effects(capture: *Capture) ConfigReloadDeliveryEffects {
    return .{
        .context = capture,
        .apply_adoption = applyAdoption,
        .publish_notification = publishNotification,
        .rearm = rearm,
    };
}

fn applyAdoption(raw_context: *anyopaque) !ConfigurationCommitType {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.record(.apply_adoption);

    if (capture.failure == .apply_adoption) {
        return error.ConfigurationAdoptionFailed;
    }

    return config_reload_delivery.testingCommit();
}

fn publishNotification(raw_context: *anyopaque, input: InputType) !void {
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

fn record(capture: *Capture, event: config_reload_delivery.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const Capture) []const config_reload_delivery.Event {
    return capture.events[0..capture.event_count];
}
