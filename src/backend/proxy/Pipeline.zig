const middleware = @import("middleware.zig");
const Observer = @import("Observer.zig");
const std = @import("std");
const MiddlewareEvent = @import("MiddlewareEvent.zig");
/// Immutable after the listener starts, so concurrent tunnels need no lock.
const Pipeline = @This();

observers: [middleware.max_observers]Observer = undefined,
len: u8 = 0,

pub fn add(self: *Pipeline, observer: Observer) !void {
    if (self.len == self.observers.len) {
        return error.TooManyProxyObservers;
    }
    self.observers[self.len] = observer;
    self.len += 1;
}

pub fn publish(self: *const Pipeline, io: std.Io, event: MiddlewareEvent) void {
    for (self.observers[0..self.len]) |observer|
        observer.observe(observer.context, io, event);
}
