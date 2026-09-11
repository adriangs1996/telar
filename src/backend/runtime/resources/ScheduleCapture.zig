const ScheduleCapture = @This();
const proxy_mod = @import("../../proxy/root.zig");
const ObservationScheduler = @import("ObservationScheduler.zig");
count: usize = 0,
capability: ?*proxy_mod.Proxy = null,
failure: ?anyerror = null,

fn schedule(context: *anyopaque, capability: *proxy_mod.Proxy) !void {
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
