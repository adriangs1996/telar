const CompletionDeliveryCapture = @This();
const source_namespace = @import("clipboard_image.zig");
const CompletionDelivery = @import("ClipboardImageCompletionDelivery.zig");
calls: usize = 0,
outcome: ?source_namespace.CompletionOutcome = null,
fail: bool = false,

pub fn port(capture: *CompletionDeliveryCapture) CompletionDelivery {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(raw_context: *anyopaque, outcome: source_namespace.CompletionOutcome) !void {
    const capture: *CompletionDeliveryCapture = @ptrCast(@alignCast(raw_context));
    capture.calls += 1;
    capture.outcome = outcome;

    if (capture.fail) {
        return error.CompletionDeliveryFailed;
    }
}
