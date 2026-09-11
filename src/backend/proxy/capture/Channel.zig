const Channel = @This();
const source_namespace = @import("queue.zig");
const Envelope = @import("Envelope.zig");
const CredentialGate = @import("CredentialGate.zig");
const std = @import("std");
const Publication = @import("QueuePublication.zig");
const buffer = @import("buffer_support.zig");
const Metrics = @import("QueueMetrics.zig");
storage: [source_namespace.capacity]Envelope = undefined,
events: source_namespace.Io.Queue(Envelope) = undefined,
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
pub fn publish(channel: *Channel, io: source_namespace.Io, publication: Publication) bool {
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
pub fn receive(channel: *Channel, io: source_namespace.Io) anyerror!*buffer.Half {
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
pub fn close(channel: *Channel, io: source_namespace.Io) void {
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
pub fn metrics(channel: *const Channel) Metrics {
    return .{
        .queued = channel.queued.load(.monotonic),
        .high_water = channel.high_water.load(.monotonic),
        .dropped = channel.dropped.load(.monotonic),
    };
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
