const queue = @import("queue.zig");
const std = @import("std");
const CredentialGate = @import("../CredentialGate.zig");
const Credential = @import("../Credential.zig");
const Half = @import("Half.zig");
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
pub fn init(self: *Channel, gate: CredentialGate) void {
    self.* = .{ .gate = gate };
    self.events = .init(&self.storage);
}

/// Attempts a zero-deadline ownership transfer and frees rejected halves.
///
/// ```zig
/// _ = channel.publish(io, .{ .credential = credential, .half = half });
/// ```
pub fn publish(self: *Channel, io: std.Io, publication: QueuePublication) bool {
    if (!self.gate.accepts(&publication.credential)) {
        publication.half.deinit();
        return false;
    }

    const depth = self.reserve() orelse {
        _ = self.dropped.fetchAdd(1, .monotonic);
        publication.half.deinit();
        return false;
    };
    var envelope: Envelope = .{ .credential = publication.credential, .half = publication.half };
    defer std.crypto.secureZero(u8, &envelope.credential.token);
    const published = self.events.put(io, &.{envelope}, 0) catch 0;

    if (published == 0) {
        self.release();
        _ = self.dropped.fetchAdd(1, .monotonic);
        publication.half.deinit();
        return false;
    }

    _ = self.high_water.fetchMax(depth, .monotonic);
    return true;
}

/// Returns the next half whose credential remains valid at delivery time.
///
/// ```zig
/// const half = try channel.receive(io);
/// ```
pub fn receive(self: *Channel, io: std.Io) anyerror!*Half {
    while (true) {
        var envelope = try self.events.getOne(io);
        defer std.crypto.secureZero(u8, &envelope.credential.token);
        self.release();

        if (self.gate.accepts(&envelope.credential)) {
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
pub fn close(self: *Channel, io: std.Io) void {
    self.events.close(io);

    while (true) {
        var envelopes: [1]Envelope = undefined;
        const count = self.events.getUncancelable(io, &envelopes, 0) catch break;
        if (count == 0) {
            break;
        }

        var envelope = envelopes[0];
        std.crypto.secureZero(u8, &envelope.credential.token);
        envelope.half.deinit();
        self.release();
    }
}

/// Reads queue depth, high-water mark, and capacity drops atomically.
///
/// ```zig
/// const metrics = channel.metrics();
/// ```
pub fn metrics(self: *const Channel) QueueMetrics {
    return .{
        .queued = self.queued.load(.monotonic),
        .high_water = self.high_water.load(.monotonic),
        .dropped = self.dropped.load(.monotonic),
    };
}

fn reserve(self: *Channel) ?u64 {
    var current = self.queued.load(.monotonic);

    while (current < queue.capacity) {
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

const QueuePublication = struct {
    credential: Credential,
    half: *Half,
};

const Envelope = struct {
    credential: Credential,
    half: *Half,
};

const QueueMetrics = struct {
    queued: u64,
    high_water: u64,
    dropped: u64,
};
