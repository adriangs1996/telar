const Channel = @This();
const source_namespace = @import("observation_queue.zig");
const middleware = @import("middleware.zig");
const CredentialGate = @import("CredentialGate.zig");
const std = @import("std");
const Metrics = @import("ObservationQueueMetrics.zig");
storage: [source_namespace.capacity]middleware.Event = undefined,
events: source_namespace.Io.Queue(middleware.Event) = undefined,
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
pub fn init(channel: *Channel, gate: CredentialGate) void {
    channel.* = .{ .gate = gate };
    channel.events = .init(&channel.storage);
}

/// Returns the observer registered in the immutable proxy pipeline.
///
/// ```zig
/// try pipeline.add(channel.observer());
/// ```
pub fn observer(channel: *Channel) middleware.Observer {
    return .{ .context = channel, .observe = observe };
}

/// Returns the next observation whose credential is still live.
/// Revoked observations are scrubbed and consumed without escaping.
/// Queue closure is reported after every already-buffered event is read.
///
/// ```zig
/// const event = try channel.receive(io);
/// ```
pub fn receive(channel: *Channel, io: source_namespace.Io) anyerror!middleware.Event {
    while (true) {
        var event = try channel.events.getOne(io);
        defer std.crypto.secureZero(u8, &event.credential.token);
        channel.release();

        if (channel.gate.accepts(&event.credential)) {
            return event;
        }
    }
}

/// Stops future publication and wakes receivers after buffered events.
///
/// ```zig
/// channel.close(io);
/// ```
pub fn close(channel: *Channel, io: source_namespace.Io) void {
    channel.events.close(io);
}

/// Returns a lock-free snapshot of reserved delivery depth, its high-water
/// mark, and publication loss.
///
/// ```zig
/// const snapshot = channel.metrics();
/// ```
pub fn metrics(channel: *const Channel) Metrics {
    return .{
        .queued = channel.queued.load(.monotonic),
        .high_water = channel.high_water.load(.monotonic),
        .dropped = channel.dropped.load(.monotonic),
    };
}

fn observe(context: *anyopaque, io: source_namespace.Io, event: middleware.Event) void {
    const channel: *Channel = @ptrCast(@alignCast(context));
    channel.publish(io, event);
}

pub fn publish(channel: *Channel, io: source_namespace.Io, event: middleware.Event) void {
    if (!channel.gate.accepts(&event.credential)) {
        return;
    }

    // A waiting receiver may consume a direct handoff before `put`
    // returns, so depth must be reserved before publication.
    const depth = channel.reserve() orelse {
        _ = channel.dropped.fetchAdd(1, .monotonic);
        return;
    };
    const published = channel.events.put(io, &.{event}, 0) catch 0;

    if (published == 0) {
        channel.release();
        _ = channel.dropped.fetchAdd(1, .monotonic);
        return;
    }

    _ = channel.high_water.fetchMax(depth, .monotonic);
}

fn reserve(channel: *Channel) ?u64 {
    var current = channel.queued.load(.monotonic);

    while (current < source_namespace.capacity) {
        if (channel.queued.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |observed| {
            current = observed;
            continue;
        }

        return current + 1;
    }

    return null;
}

fn release(channel: *Channel) void {
    const previous = channel.queued.fetchSub(1, .monotonic);
    std.debug.assert(previous != 0);
}
