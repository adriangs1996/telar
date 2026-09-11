const ModelType = @import("../../model/Model.zig");
const plugin_action = @import("plugin_action.zig");
const PluginActionStartEffects = @import("PluginActionStartEffects.zig");
const StartDelivery = @import("StartDelivery.zig");
const PluginExecutionType = @import("../../model/PluginExecution.zig");
const std = @import("std");
const StartCapture = @This();

model: *const ModelType,
prepare_calls: usize = 0,
schedule_calls: usize = 0,
delivery_calls: usize = 0,
prepared_before_commit: bool = false,
scheduled_after_commit: bool = false,
prepare_error: ?anyerror = null,
fail_schedule: bool = false,
fail_delivery: bool = false,
delivered_outcome: ?plugin_action.StartOutcome = null,

pub fn port(capture: *StartCapture) PluginActionStartEffects {
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

fn schedule(raw_context: *anyopaque, execution: PluginExecutionType) !void {
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

fn deliver(raw_context: *anyopaque, outcome: plugin_action.StartOutcome) !void {
    const capture: *StartCapture = @ptrCast(@alignCast(raw_context));
    capture.delivery_calls += 1;
    capture.delivered_outcome = outcome;

    if (capture.fail_delivery) {
        return error.PluginStartDeliveryFailed;
    }
}
