const StartCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("plugin_action.zig");
const StartEffects = @import("PluginActionStartEffects.zig");
const StartDelivery = @import("StartDelivery.zig");
const std = @import("std");
model: *const client_model.Model,
prepare_calls: usize = 0,
schedule_calls: usize = 0,
delivery_calls: usize = 0,
prepared_before_commit: bool = false,
scheduled_after_commit: bool = false,
prepare_error: ?anyerror = null,
fail_schedule: bool = false,
fail_delivery: bool = false,
delivered_outcome: ?source_namespace.StartOutcome = null,

pub fn port(capture: *StartCapture) StartEffects {
    return .{
        .context = capture,
        .prepare = prepare,
        .schedule = schedule,
    };
}

pub fn delivery(capture: *StartCapture) StartDelivery {
    return .{ .context = capture, .deliver = deliver };
}

fn prepare(raw_context: *anyopaque) !void {
    const capture: *StartCapture = @ptrCast(@alignCast(raw_context));
    capture.prepare_calls += 1;
    capture.prepared_before_commit = capture.model.pluginExecution() == null;
    if (capture.prepare_error) |err| {
        return err;
    }
}

fn schedule(raw_context: *anyopaque, execution: client_model.PluginExecution) !void {
    const capture: *StartCapture = @ptrCast(@alignCast(raw_context));
    capture.schedule_calls += 1;
    capture.scheduled_after_commit = std.meta.eql(
        capture.model.pluginExecution().?,
        execution,
    );
    if (capture.fail_schedule) {
        return error.PluginScheduleFailed;
    }
}

fn deliver(raw_context: *anyopaque, outcome: source_namespace.StartOutcome) !void {
    const capture: *StartCapture = @ptrCast(@alignCast(raw_context));
    capture.delivery_calls += 1;
    capture.delivered_outcome = outcome;

    if (capture.fail_delivery) {
        return error.PluginStartDeliveryFailed;
    }
}
