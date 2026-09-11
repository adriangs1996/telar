const CompletionDeliveryCapture = @This();
const source_namespace = @import("plugin_action.zig");
const CompletionDelivery = @import("PluginActionCompletionDelivery.zig");
calls: usize = 0,
outcome: ?source_namespace.CompletionOutcome = null,
fail: bool = false,

pub fn port(capture: *CompletionDeliveryCapture) CompletionDelivery {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(raw_context: *anyopaque, outcome: source_namespace.CompletionOutcome) !source_namespace.CompletionDirective {
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
