const DeliveryType = @import("../entrypoints/requests/Delivery.zig");
const PumpCapture = @This();

count: usize = 0,

pub fn delivery(capture: *PumpCapture) DeliveryType {
    return .{ .context = capture, .pump_all_fn = pumpAll };
}

fn pumpAll(context: *anyopaque) void {
    const capture: *PumpCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
}
