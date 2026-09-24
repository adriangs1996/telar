const dropqueue = @import("dropqueue");
const observation_queue = @import("observation_queue.zig");
const MiddlewareEvent = @import("MiddlewareEvent.zig");
const std = @import("std");
const Registry = @import("Registry.zig");
const QueueMetrics = dropqueue.QueueMetrics;
const Events = dropqueue.GenericDropQueue(MiddlewareEvent, observation_queue.capacity);
const Channel = @This();

events: Events = undefined,
/// Live pane credentials, checked at publication and again at delivery.
credentials: *Registry = undefined,

/// Initializes queue storage at its final address over the registry whose
/// live credentials admit events at publication and delivery time.
///
/// ```zig
/// channel.init(&registry);
/// ```
pub fn init(self: *Channel, credentials: *Registry) void {
    self.credentials = credentials;
    self.events.init();
}

/// Returns the next observation whose credential is still live.
/// Revoked observations are scrubbed and consumed without escaping.
/// Queue closure is reported after every already-buffered event is read.
///
/// ```zig
/// const event = try channel.receive(io);
/// ```
pub fn receive(self: *Channel, io: std.Io) anyerror!MiddlewareEvent {
    while (true) {
        var event = try self.events.receive(io);
        defer std.crypto.secureZero(u8, &event.credential.token);

        if (self.credentials.contains(io, &event.credential)) {
            return event;
        }
    }
}

/// Returns the next buffered observation whose credential is still live,
/// or null when none is buffered. Never waits.
///
/// ```zig
/// while (channel.tryReceive(io)) |event| consume(event);
/// ```
pub fn tryReceive(self: *Channel, io: std.Io) ?MiddlewareEvent {
    while (self.events.tryReceive(io)) |received| {
        var event = received;
        defer std.crypto.secureZero(u8, &event.credential.token);

        if (self.credentials.contains(io, &event.credential)) {
            return event;
        }
    }

    return null;
}

/// Stops future publication and wakes receivers after buffered events.
///
/// ```zig
/// channel.close(io);
/// ```
pub fn close(self: *Channel, io: std.Io) void {
    self.events.close(io);
}

/// Returns a lock-free snapshot of reserved delivery depth, its high-water
/// mark, and publication loss.
///
/// ```zig
/// const snapshot = channel.metrics();
/// ```
pub fn metrics(self: *const Channel) QueueMetrics {
    return self.events.metrics();
}

/// Queues one observation whose credential is live, without waiting: a full
/// queue drops it and counts the loss.
///
/// ```zig
/// channel.publish(io, event);
/// ```
pub fn publish(self: *Channel, io: std.Io, event: MiddlewareEvent) void {
    if (!self.credentials.contains(io, &event.credential)) {
        return;
    }

    _ = self.events.publish(io, event);
}
