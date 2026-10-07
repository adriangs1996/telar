const event_loop = @import("event_loop.zig");
const event = @import("event.zig");
const std = @import("std");
/// Owns the bounded selector for one runtime.
const Loop = @This();

storage: [event_loop.event_capacity]event.Event,
select: std.Io.Select(event.Event),

/// Initializes bounded event storage without starting any actor.
///
/// ```zig
/// var loop: Loop = undefined;
/// loop.init(io);
/// ```
pub fn init(self: *Loop, io: std.Io) void {
    self.select = std.Io.Select(event.Event).init(io, &self.storage);
}

/// Returns the selector borrowed by runtime event sources and procedures.
///
/// ```zig
/// const select = loop.selector();
/// ```
pub fn selector(self: *Loop) *std.Io.Select(event.Event) {
    return &self.select;
}

/// Waits until one scheduled actor produces an event.
///
/// ```zig
/// const event = try loop.next();
/// ```
pub fn next(self: *Loop) !event.Event {
    return self.select.await();
}

/// Joins every scheduled actor, then releases undispatched event ownership.
///
/// ```zig
/// loop.cancel();
/// ```
pub fn cancel(self: *Loop) void {
    while (self.select.cancel()) |completed| {
        event.discard(completed, self.select.io);
    }
}
