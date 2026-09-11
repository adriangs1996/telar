const clipboard_image = @import("clipboard_image.zig");
const ClipboardImageCompletionDelivery = @import("ClipboardImageCompletionDelivery.zig");
const CompletionDeliveryCapture = @This();

calls: usize = 0,
outcome: ?clipboard_image.CompletionOutcome = null,
fail: bool = false,

pub fn port(capture: *CompletionDeliveryCapture) ClipboardImageCompletionDelivery {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(raw_context: *anyopaque, outcome: clipboard_image.CompletionOutcome) !void {
    const capture: *CompletionDeliveryCapture = @ptrCast(@alignCast(raw_context));
    capture.calls += 1;
    capture.outcome = outcome;

    if (capture.fail) {
        return error.CompletionDeliveryFailed;
    }
}
