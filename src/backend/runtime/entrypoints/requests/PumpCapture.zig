const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const Delivery = @import("Delivery.zig");
const PumpCapture = @This();

responses: *ResponseQueueType,
expected_delivered: u8,
call_count: usize = 0,
observed_committed_confirmation: bool = false,

pub fn delivery(capture: *PumpCapture) Delivery {
    return .{ .context = capture, .pump_all_fn = pumpAll };
}

fn pumpAll(context: *anyopaque) void {
    const capture: *PumpCapture = @ptrCast(@alignCast(context));
    capture.call_count += 1;
    const response = capture.responses.peek().?;
    capture.observed_committed_confirmation = response.* == .notification_shown and
        response.notification_shown.delivered_clients == capture.expected_delivered;
}
