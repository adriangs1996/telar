const observation_queue = @import("observation_queue.zig");
const MiddlewareEvent = @import("MiddlewareEvent.zig");
const std = @import("std");
const Registry = @import("Registry.zig");
const ObservationQueueMetrics = @import("ObservationQueueMetrics.zig");
const Channel = @This();

storage: [observation_queue.capacity]MiddlewareEvent = undefined,
events: std.Io.Queue(MiddlewareEvent) = undefined,
/// Live pane credentials, checked at publication and again at delivery.
credentials: *Registry = undefined,
queued: std.atomic.Value(u64) = .init(0),
high_water: std.atomic.Value(u64) = .init(0),
dropped: std.atomic.Value(u64) = .init(0),

/// Initializes queue storage at its final address over the registry whose
/// live credentials admit events at publication and delivery time.
///
/// ```zig
/// channel.init(&registry);
/// ```
pub fn init(self: *Channel, credentials: *Registry) void {
    self.* = .{ .credentials = credentials };
    self.events = .init(&self.storage);
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
        var event = try self.events.getOne(io);
        defer std.crypto.secureZero(u8, &event.credential.token);
        self.release();

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
    while (true) {
        var events: [1]MiddlewareEvent = undefined;
        const count = self.events.getUncancelable(io, &events, 0) catch return null;
        if (count == 0) {
            return null;
        }

        var event = events[0];
        defer std.crypto.secureZero(u8, &event.credential.token);
        self.release();
        if (self.credentials.contains(io, &event.credential)) {
            return event;
        }
    }
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
pub fn metrics(self: *const Channel) ObservationQueueMetrics {
    return .{
        .queued = self.queued.load(.monotonic),
        .high_water = self.high_water.load(.monotonic),
        .dropped = self.dropped.load(.monotonic),
    };
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

    // A waiting receiver may consume a direct handoff before `put`
    // returns, so depth must be reserved before publication.
    const depth = self.reserve() orelse {
        _ = self.dropped.fetchAdd(1, .monotonic);
        return;
    };
    const published = self.events.put(io, &.{event}, 0) catch 0;

    if (published == 0) {
        self.release();
        _ = self.dropped.fetchAdd(1, .monotonic);
        return;
    }

    _ = self.high_water.fetchMax(depth, .monotonic);
}

fn reserve(self: *Channel) ?u64 {
    var current = self.queued.load(.monotonic);

    while (current < observation_queue.capacity) {
        if (self.queued.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |observed| {
            current = observed;
            continue;
        }

        return current + 1;
    }

    return null;
}

fn release(self: *Channel) void {
    const previous = self.queued.fetchSub(1, .monotonic);
    std.debug.assert(previous != 0);
}
