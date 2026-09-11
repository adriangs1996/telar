const CaptureSink = @This();
const proxy_mod = @import("../../proxy/root.zig");
context: *anyopaque,
submit_fn: *const fn (*anyopaque, *proxy_mod.CaptureExchange) void,

pub fn submit(sink: CaptureSink, exchange: *proxy_mod.CaptureExchange) void {
    sink.submit_fn(sink.context, exchange);
}
