const middleware = @import("middleware.zig");
const Observer = @import("Observer.zig");
const std = @import("std");
const MiddlewareEvent = @import("MiddlewareEvent.zig");
/// Immutable after the listener starts, so concurrent tunnels need no lock.
const Pipeline = @This();

observers: [middleware.max_observers]Observer = undefined,
len: u8 = 0,

pub fn add(pipeline: *Pipeline, observer: Observer) !void {
    if (pipeline.len == pipeline.observers.len) {
        return error.TooManyProxyObservers;
    }
    pipeline.observers[pipeline.len] = observer;
    pipeline.len += 1;
}

pub fn publish(pipeline: *const Pipeline, io: std.Io, event: MiddlewareEvent) void {
    for (pipeline.observers[0..pipeline.len]) |observer|
        observer.observe(observer.context, io, event);
}
