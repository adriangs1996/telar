const MiddlewareEvent = @import("../MiddlewareEvent.zig");
const std = @import("std");
const Capture = @This();

events: [8]MiddlewareEvent = undefined,
len: usize = 0,

pub fn observe(context: *anyopaque, _: std.Io, event: MiddlewareEvent) void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.events[capture.len] = event;
    capture.len += 1;
}
