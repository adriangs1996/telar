const ObservationScheduler = @This();
const proxy_mod = @import("../../proxy/root.zig");
context: *anyopaque,
schedule_fn: *const fn (*anyopaque, *proxy_mod.Proxy) anyerror!void,

pub fn schedule(scheduler: ObservationScheduler, proxy: *proxy_mod.Proxy) !void {
    return scheduler.schedule_fn(scheduler.context, proxy);
}
