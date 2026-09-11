const Capture = @This();
const middleware = @import("../middleware.zig");
const source_namespace = @import("http1.zig");
events: [16]middleware.Event = undefined,
len: usize = 0,

pub fn observe(context: *anyopaque, _: source_namespace.Io, event: middleware.Event) void {
    const observed: *Capture = @ptrCast(@alignCast(context));
    observed.events[observed.len] = event;
    observed.len += 1;
}
