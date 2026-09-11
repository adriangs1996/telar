const Exchange = @import("../../proxy/capture/Exchange.zig");
const CaptureSink = @This();

context: *anyopaque,
submit_fn: *const fn (*anyopaque, *Exchange) void,

pub fn submit(sink: CaptureSink, exchange: *Exchange) void {
    sink.submit_fn(sink.context, exchange);
}
