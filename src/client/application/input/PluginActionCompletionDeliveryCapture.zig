const plugin_action = @import("plugin_action.zig");
const PluginActionCompletionDelivery = @import("PluginActionCompletionDelivery.zig");
const CompletionDeliveryCapture = @This();

calls: usize = 0,
outcome: ?plugin_action.CompletionOutcome = null,
fail: bool = false,

pub fn port(capture: *CompletionDeliveryCapture) PluginActionCompletionDelivery {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(raw_context: *anyopaque, outcome: plugin_action.CompletionOutcome) !plugin_action.CompletionDirective {
    const capture: *CompletionDeliveryCapture = @ptrCast(@alignCast(raw_context));
    capture.calls += 1;
    capture.outcome = outcome;

    if (capture.fail) {
        return error.PluginCompletionDeliveryFailed;
    }

    return switch (outcome) {
        .exit => .exit_client,
        else => .continue_client,
    };
}
