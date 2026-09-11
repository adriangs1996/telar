const ModelType = @import("../../model/Model.zig");
const plugin_action = @import("plugin_action.zig");
const PluginActionCompletionEffects = @import("PluginActionCompletionEffects.zig");
const PluginResult = @import("PluginResult.zig");
const EffectBatchType = @import("../../config/EffectBatch.zig");
const CompletionCapture = @This();

model: *const ModelType,
events: [2]plugin_action.CompletionEvent = undefined,
event_count: usize = 0,
observed_finished: bool = false,
fail_authorize: bool = false,
fail_apply: bool = false,
disposition: plugin_action.BatchDisposition = .continue_client,

pub fn port(capture: *CompletionCapture) PluginActionCompletionEffects {
    return .{
        .context = capture,
        .authorize = authorize,
        .apply = apply,
    };
}

fn authorize(raw_context: *anyopaque, result: PluginResult) !void {
    const capture: *CompletionCapture = @ptrCast(@alignCast(raw_context));
    _ = result;
    capture.events[capture.event_count] = .authorize;
    capture.event_count += 1;
    capture.observed_finished = capture.model.pluginExecution() == null;
    if (capture.fail_authorize) {
        return error.PluginAuthorizationFailed;
    }
}

fn apply(raw_context: *anyopaque, batch: *const EffectBatchType) !plugin_action.BatchDisposition {
    const capture: *CompletionCapture = @ptrCast(@alignCast(raw_context));
    _ = batch;
    capture.events[capture.event_count] = .apply;
    capture.event_count += 1;
    capture.observed_finished = capture.observed_finished and
        capture.model.pluginExecution() == null;
    if (capture.fail_apply) {
        return error.PluginEffectsFailed;
    }

    return capture.disposition;
}
