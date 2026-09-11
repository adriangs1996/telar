const ProxyType = @import("../../proxy/Proxy.zig");
const ObservationScheduler = @This();

context: *anyopaque,
schedule_fn: *const fn (*anyopaque, *ProxyType) anyerror!void,

pub fn schedule(scheduler: ObservationScheduler, proxy: *ProxyType) !void {
    return scheduler.schedule_fn(scheduler.context, proxy);
}
