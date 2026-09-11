const MiddlewareEvent = @import("../MiddlewareEvent.zig");
const std = @import("std");
const Capture = @This();

events: [16]MiddlewareEvent = undefined,
len: usize = 0,

pub fn observe(context: *anyopaque, _: std.Io, event: MiddlewareEvent) void {
    const observed: *Capture = @ptrCast(@alignCast(context));
    observed.events[observed.len] = event;
    observed.len += 1;
}
