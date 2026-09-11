const ProxyCaptureScheduleContext = @This();
const Sources = @import("Sources.zig");
const proxy_resource = @import("resources/proxy.zig");
const proxy_mod = @import("../proxy/root.zig");
sources: *Sources,

pub fn scheduler(context: *ProxyCaptureScheduleContext) proxy_resource.CaptureScheduler {
    return .{ .context = context, .schedule_fn = schedule };
}

fn schedule(context_value: *anyopaque, proxy: *proxy_mod.Proxy) !void {
    const context: *ProxyCaptureScheduleContext = @ptrCast(@alignCast(context_value));
    try context.sources.select.concurrent(.proxy_capture, proxy_mod.Proxy.receiveCapture, .{ proxy, context.sources.io });
}
