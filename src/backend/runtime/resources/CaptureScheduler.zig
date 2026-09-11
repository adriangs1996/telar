const ProxyType = @import("../../proxy/Proxy.zig");
const CaptureScheduler = @This();

context: *anyopaque,
schedule_fn: *const fn (*anyopaque, *ProxyType) anyerror!void,

pub fn schedule(scheduler: CaptureScheduler, proxy: *ProxyType) !void {
    return scheduler.schedule_fn(scheduler.context, proxy);
}
