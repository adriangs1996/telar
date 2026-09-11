const Capture = @This();
const middleware = @import("../middleware.zig");
const source_namespace = @import("exchange_support.zig");
events: [8]middleware.Event = undefined,
len: usize = 0,

pub fn observe(context: *anyopaque, _: source_namespace.Io, event: middleware.Event) void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.events[capture.len] = event;
    capture.len += 1;
}
