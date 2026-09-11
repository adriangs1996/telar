const Sources = @import("Sources.zig");
const CaptureSchedulerType = @import("resources/CaptureScheduler.zig");
const ProxyType = @import("../proxy/Proxy.zig");
const ProxyCaptureScheduleContext = @This();

sources: *Sources,

pub fn scheduler(context: *ProxyCaptureScheduleContext) CaptureSchedulerType {
    return .{ .context = context, .schedule_fn = schedule };
}

fn schedule(context_value: *anyopaque, proxy: *ProxyType) !void {
    const context: *ProxyCaptureScheduleContext = @ptrCast(@alignCast(context_value));
    try context.sources.select.concurrent(.proxy_capture, ProxyType.receiveCapture, .{ proxy, context.sources.io });
}
