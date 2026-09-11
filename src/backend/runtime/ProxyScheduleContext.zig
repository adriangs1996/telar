const Sources = @import("Sources.zig");
const ObservationSchedulerType = @import("resources/ObservationScheduler.zig");
const ProxyType = @import("../proxy/Proxy.zig");
const ProxyScheduleContext = @This();

sources: *Sources,

pub fn scheduler(context: *ProxyScheduleContext) ObservationSchedulerType {
    return .{ .context = context, .schedule_fn = schedule };
}

fn schedule(context_value: *anyopaque, proxy: *ProxyType) !void {
    const context: *ProxyScheduleContext = @ptrCast(@alignCast(context_value));
    try context.sources.select.concurrent(.proxy_event, ProxyType.receive, .{ proxy, context.sources.io });
}
