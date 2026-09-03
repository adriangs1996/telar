//! Bounded pointer-transfer queue for captured exchange halves.

const std = @import("std");
const buffer = @import("buffer.zig");
const identity = @import("../identity.zig");

const Io = std.Io;

pub const capacity = 256;

pub const CredentialGate = struct {
    context: *anyopaque,
    is_live: *const fn (*anyopaque, *const identity.Credential) bool,

    fn accepts(gate: CredentialGate, credential: *const identity.Credential) bool {
        return gate.is_live(gate.context, credential);
    }
};

pub const Metrics = struct {
    queued: u64,
    high_water: u64,
    dropped: u64,
};

const Envelope = struct {
    credential: identity.Credential,
    half: *buffer.Half,
};

pub const Publication = struct {
    credential: identity.Credential,
    half: *buffer.Half,
};

pub const Channel = struct {
    storage: [capacity]Envelope = undefined,
    events: Io.Queue(Envelope) = undefined,
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
    pub fn publish(channel: *Channel, io: Io, publication: Publication) bool {
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
    pub fn receive(channel: *Channel, io: Io) anyerror!*buffer.Half {
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
    pub fn close(channel: *Channel, io: Io) void {
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

        while (current < capacity) {
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
};

const GateState = struct {
    generation: u64 = 1,

    fn accepts(context: *anyopaque, credential: *const identity.Credential) bool {
        const state: *const GateState = @ptrCast(@alignCast(context));
        return credential.pane_generation == state.generation;
    }
};

fn testCredential(generation: u64) identity.Credential {
    return .{
        .pane_id = @enumFromInt(7),
        .pane_generation = generation,
        .token = .{0x5a} ** identity.token_bytes,
    };
}

fn testHalf(quota: *buffer.Quota, credential: identity.Credential, stream_id: u32) *buffer.Half {
    return buffer.Half.create(.{
        .gpa = std.testing.allocator,
        .quota = quota,
        .config = .{
            .enabled = true,
            .max_part_bytes = 1,
            .max_exchange_bytes = 2,
            .max_total_bytes = capacity + 1,
        },
        .credential = credential,
        .dialect = .unknown,
        .protocol = .h2,
        .key = .{ .connection_id = 1, .stream_id = stream_id },
        .side = .request,
        .host = "example.test",
        .started_at_ms = 1,
    }).?;
}

test "queue saturation drops and frees the rejected half" {
    var gate_state: GateState = .{};
    var channel: Channel = undefined;
    channel.init(.{ .context = &gate_state, .is_live = GateState.accepts });
    var quota = buffer.Quota.init(capacity + 1);
    const credential = testCredential(1);

    for (0..capacity) |index| {
        try std.testing.expect(channel.publish(std.testing.io, .{
            .credential = credential,
            .half = testHalf(&quota, credential, @intCast(index + 1)),
        }));
    }
    try std.testing.expect(!channel.publish(std.testing.io, .{
        .credential = credential,
        .half = testHalf(&quota, credential, capacity + 1),
    }));
    try std.testing.expectEqual(@as(usize, capacity), quota.used());
    try std.testing.expectEqual(@as(u64, 1), channel.metrics().dropped);

    channel.close(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), quota.used());
    try std.testing.expectEqual(@as(u64, 0), channel.metrics().queued);
}

test "delivery rejects a credential revoked after publication" {
    var gate_state: GateState = .{};
    var channel: Channel = undefined;
    channel.init(.{ .context = &gate_state, .is_live = GateState.accepts });
    defer channel.close(std.testing.io);
    var quota = buffer.Quota.init(2);
    const credential = testCredential(1);
    try std.testing.expect(channel.publish(std.testing.io, .{
        .credential = credential,
        .half = testHalf(&quota, credential, 1),
    }));

    gate_state.generation = 2;
    channel.close(std.testing.io);
    try std.testing.expectError(error.Closed, channel.receive(std.testing.io));
    try std.testing.expectEqual(@as(usize, 0), quota.used());
}
