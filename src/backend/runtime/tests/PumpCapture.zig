const PumpCapture = @This();
const show_notification_controller = @import("../entrypoints/requests/show_notification.zig");
count: usize = 0,

pub fn delivery(capture: *PumpCapture) show_notification_controller.Delivery {
    return .{ .context = capture, .pump_all_fn = pumpAll };
}

fn pumpAll(context: *anyopaque) void {
    const capture: *PumpCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
}
