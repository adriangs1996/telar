const queue = @import("queue.zig");
const Envelope = @import("Envelope.zig");
const std = @import("std");
const CredentialGate = @import("CredentialGate.zig");
const QueuePublication = @import("QueuePublication.zig");
const HalfType = @import("Half.zig");
const QueueMetrics = @import("QueueMetrics.zig");
const Channel = @This();

storage: [queue.capacity]Envelope = undefined,
events: std.Io.Queue(Envelope) = undefined,
gate: CredentialGate = undefined,
queued: std.atomic.Value(u64) = .init(0),
high_water: std.atomic.Value(u64) = .init(0),
dropped: std.atomic.Value(u64) = .init(0),

/// Initializes fixed queue storage and its pane-credential gate.
///
/// ```zig
/// channel.init(gate);
/// ```
pub fn init(channel: *Channel, gate: CredentialGate) void {
    channel.* = .{ .gate = gate };
    channel.events = .init(&channel.storage);
}

/// Attempts a zero-deadline ownership transfer and frees rejected halves.
///
/// ```zig
/// _ = channel.publish(io, .{ .credential = credential, .half = half });
/// ```
pub fn publish(channel: *Channel, io: std.Io, publication: QueuePublication) bool {
    if (!channel.gate.accepts(&publication.credential)) {
        publication.half.deinit();
        return false;
    }

    const depth = channel.reserve() orelse {
        _ = channel.dropped.fetchAdd(1, .monotonic);
        publication.half.deinit();
        return false;
    };
    var envelope: Envelope = .{ .credential = publication.credential, .half = publication.half };
    defer std.crypto.secureZero(u8, &envelope.credential.token);
    const published = channel.events.put(io, &.{envelope}, 0) catch 0;

    if (published == 0) {
        channel.release();
        _ = channel.dropped.fetchAdd(1, .monotonic);
        publication.half.deinit();
        return false;
    }

    _ = channel.high_water.fetchMax(depth, .monotonic);
    return true;
}

/// Returns the next half whose credential remains valid at delivery time.
///
/// ```zig
/// const half = try channel.receive(io);
/// ```
pub fn receive(channel: *Channel, io: std.Io) anyerror!*HalfType {
    while (true) {
        var envelope = try channel.events.getOne(io);
        defer std.crypto.secureZero(u8, &envelope.credential.token);
        channel.release();

        if (channel.gate.accepts(&envelope.credential)) {
            return envelope.half;
        }

        envelope.half.deinit();
    }
}

/// Closes the channel and frees all buffered half ownership.
///
/// ```zig
/// channel.close(io);
/// ```
pub fn close(channel: *Channel, io: std.Io) void {
    channel.events.close(io);

    while (true) {
        var envelopes: [1]Envelope = undefined;
        const count = channel.events.getUncancelable(io, &envelopes, 0) catch break;
        if (count == 0) {
            break;
        }

        var envelope = envelopes[0];
        std.crypto.secureZero(u8, &envelope.credential.token);
        envelope.half.deinit();
        channel.release();
    }
}

/// Reads queue depth, high-water mark, and capacity drops atomically.
///
/// ```zig
/// const metrics = channel.metrics();
/// ```
pub fn metrics(channel: *const Channel) QueueMetrics {
    return .{
        .queued = channel.queued.load(.monotonic),
        .high_water = channel.high_water.load(.monotonic),
        .dropped = channel.dropped.load(.monotonic),
    };
}

fn reserve(channel: *Channel) ?u64 {
    var current = channel.queued.load(.monotonic);

    while (current < queue.capacity) {
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
