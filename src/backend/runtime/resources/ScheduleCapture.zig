const ProxyType = @import("../../proxy/Proxy.zig");
const ObservationScheduler = @import("ObservationScheduler.zig");
const ScheduleCapture = @This();

count: usize = 0,
capability: ?*ProxyType = null,
failure: ?anyerror = null,

fn schedule(context: *anyopaque, capability: *ProxyType) !void {
    const capture: *ScheduleCapture = @ptrCast(@alignCast(context));
    capture.count += 1;
    capture.capability = capability;

    if (capture.failure) |err| {
        return err;
    }
}

pub fn scheduler(capture: *ScheduleCapture) ObservationScheduler {
    return .{ .context = capture, .schedule_fn = schedule };
}
