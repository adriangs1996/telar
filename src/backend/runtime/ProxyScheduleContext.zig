const ProxyScheduleContext = @This();
const Sources = @import("Sources.zig");
const proxy_resource = @import("resources/proxy.zig");
const proxy_mod = @import("../proxy/root.zig");
sources: *Sources,

pub fn scheduler(context: *ProxyScheduleContext) proxy_resource.ObservationScheduler {
    return .{ .context = context, .schedule_fn = schedule };
}

fn schedule(context_value: *anyopaque, proxy: *proxy_mod.Proxy) !void {
    const context: *ProxyScheduleContext = @ptrCast(@alignCast(context_value));
    try context.sources.select.concurrent(.proxy_event, proxy_mod.Proxy.receive, .{ proxy, context.sources.io });
}
