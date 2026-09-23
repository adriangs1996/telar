const event_loop = @import("event_loop.zig");
const event = @import("event.zig");
const std = @import("std");
/// Owns the bounded selector and the optional external stop queue for one
/// runtime.
const Loop = @This();

/// Test seam: a queue whose token stops the otherwise long-lived runtime.
stop: ?*std.Io.Queue(u8),
storage: [event_loop.event_capacity]event.Event,
select: std.Io.Select(event.Event),

/// Initializes bounded event storage without starting any actor.
///
/// ```zig
/// var loop: Loop = undefined;
/// loop.init(io, stop_queue);
/// ```
pub fn init(self: *Loop, io: std.Io, stop: ?*std.Io.Queue(u8)) void {
    self.stop = stop;
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

/// Completes the stop wait: success stops the loop and a failed wait
/// surfaces its exact error.
///
/// ```zig
/// if (try loop.completeStop(result)) return;
/// ```
pub fn completeStop(self: *Loop, result: anyerror!void) !bool {
    std.debug.assert(self.stop != null);
    try result;
    return true;
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

test "a stop completion ends the loop and a failed one keeps its error" {
    var storage: [1]u8 = undefined;
    var queue: std.Io.Queue(u8) = .init(&storage);
    var loop: Loop = undefined;
    loop.stop = &queue;

    try std.testing.expect(try loop.completeStop({}));
    try std.testing.expectError(error.StopSourceClosed, loop.completeStop(error.StopSourceClosed));
}
