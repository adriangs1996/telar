const CompletionCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("plugin_action.zig");
const CompletionEffects = @import("PluginActionCompletionEffects.zig");
const PluginResult = @import("PluginResult.zig");
const config = @import("../../config/root.zig");
model: *const client_model.Model,
events: [2]source_namespace.CompletionEvent = undefined,
event_count: usize = 0,
observed_finished: bool = false,
fail_authorize: bool = false,
fail_apply: bool = false,
disposition: source_namespace.BatchDisposition = .continue_client,

pub fn port(capture: *CompletionCapture) CompletionEffects {
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

fn apply(raw_context: *anyopaque, batch: *const config.EffectBatch) !source_namespace.BatchDisposition {
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
