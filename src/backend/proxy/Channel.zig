const observation_queue = @import("observation_queue.zig");
const MiddlewareEvent = @import("MiddlewareEvent.zig");
const std = @import("std");
const CredentialGate = @import("CredentialGate.zig");
const Observer = @import("Observer.zig");
const ObservationQueueMetrics = @import("ObservationQueueMetrics.zig");
const Channel = @This();

storage: [observation_queue.capacity]MiddlewareEvent = undefined,
events: std.Io.Queue(MiddlewareEvent) = undefined,
gate: CredentialGate = undefined,
queued: std.atomic.Value(u64) = .init(0),
high_water: std.atomic.Value(u64) = .init(0),
dropped: std.atomic.Value(u64) = .init(0),

/// Initializes queue storage at its final address and installs the live
/// credential policy used at publication and delivery time.
///
/// ```zig
/// channel.init(gate);
/// ```
pub fn init(self: *Channel, gate: CredentialGate) void {
    self.* = .{ .gate = gate };
    self.events = .init(&self.storage);
}

/// Returns the observer registered in the immutable proxy pipeline.
///
/// ```zig
/// try pipeline.add(channel.observer());
/// ```
pub fn observer(self: *Channel) Observer {
    return .{ .context = self, .observe = observe };
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

        if (self.gate.accepts(&event.credential)) {
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

fn observe(context: *anyopaque, io: std.Io, event: MiddlewareEvent) void {
    const channel: *Channel = @ptrCast(@alignCast(context));
    channel.publish(io, event);
}

pub fn publish(self: *Channel, io: std.Io, event: MiddlewareEvent) void {
    if (!self.gate.accepts(&event.credential)) {
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
