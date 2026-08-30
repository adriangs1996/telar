//! Bounded delivery channel for proxy observations.

const std = @import("std");
const identity = @import("identity.zig");
const middleware = @import("middleware.zig");

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

pub const Channel = struct {
    storage: [capacity]middleware.Event = undefined,
    events: Io.Queue(middleware.Event) = undefined,
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
    pub fn receive(channel: *Channel, io: Io) anyerror!middleware.Event {
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
    pub fn close(channel: *Channel, io: Io) void {
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

    fn observe(context: *anyopaque, io: Io, event: middleware.Event) void {
        const channel: *Channel = @ptrCast(@alignCast(context));
        channel.publish(io, event);
    }

    fn publish(channel: *Channel, io: Io, event: middleware.Event) void {
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
    live_generation: u64 = 1,

    fn isLive(context: *anyopaque, credential: *const identity.Credential) bool {
        const state: *GateState = @ptrCast(@alignCast(context));
        return credential.pane_generation == state.live_generation;
    }

    fn gate(state: *GateState) CredentialGate {
        return .{ .context = state, .is_live = isLive };
    }
};

fn testEvent(generation: u64, connection_id: u64) middleware.Event {
    return .{
        .credential = .{
            .pane_id = @enumFromInt(7),
            .pane_generation = generation,
            .token = .{0x5a} ** identity.token_bytes,
        },
        .provider = .claude,
        .phase = .request_started,
        .protocol = .http11,
        .connection_id = connection_id,
        .observed_at_ms = 1,
    };
}

fn publishBatch(channel: *Channel, io: Io, first_connection_id: u64) void {
    for (0..64) |index| {
        channel.publish(io, testEvent(1, first_connection_id + @as(u64, @intCast(index))));
    }
}

test "publication rejects revoked credentials without consuming capacity" {
    var state: GateState = .{};
    var channel: Channel = undefined;
    channel.init(state.gate());

    channel.publish(std.testing.io, testEvent(2, 1));

    try std.testing.expectEqualDeep(Metrics{ .queued = 0, .high_water = 0, .dropped = 0 }, channel.metrics());
}

test "bounded publication records depth high water and loss" {
    var state: GateState = .{};
    var channel: Channel = undefined;
    channel.init(state.gate());

    for (0..capacity) |index| {
        channel.publish(std.testing.io, testEvent(1, index));
    }
    channel.publish(std.testing.io, testEvent(1, capacity));

    try std.testing.expectEqualDeep(Metrics{
        .queued = capacity,
        .high_water = capacity,
        .dropped = 1,
    }, channel.metrics());

    for (0..capacity) |index| {
        var event = try channel.receive(std.testing.io);
        defer std.crypto.secureZero(u8, &event.credential.token);
        try std.testing.expectEqual(@as(u64, index), event.connection_id);
    }

    try std.testing.expectEqual(@as(u64, 0), channel.metrics().queued);
}

test "concurrent publishers cannot reserve beyond the fixed bound" {
    const publisher_count = 8;
    const events_per_publisher = 64;
    var state: GateState = .{};
    var channel: Channel = undefined;
    channel.init(state.gate());
    var publishers: Io.Group = .init;

    for (0..publisher_count) |index| {
        try publishers.concurrent(std.testing.io, publishBatch, .{
            &channel,
            std.testing.io,
            @as(u64, @intCast(index * events_per_publisher)),
        });
    }
    try publishers.await(std.testing.io);

    try std.testing.expectEqualDeep(Metrics{
        .queued = capacity,
        .high_water = capacity,
        .dropped = publisher_count * events_per_publisher - capacity,
    }, channel.metrics());

    for (0..capacity) |_| {
        var event = try channel.receive(std.testing.io);
        std.crypto.secureZero(u8, &event.credential.token);
    }
}

test "delivery discards events revoked after publication" {
    var state: GateState = .{};
    var channel: Channel = undefined;
    channel.init(state.gate());

    channel.publish(std.testing.io, testEvent(1, 1));
    state.live_generation = 2;
    channel.publish(std.testing.io, testEvent(2, 2));

    var event = try channel.receive(std.testing.io);
    defer std.crypto.secureZero(u8, &event.credential.token);

    try std.testing.expectEqual(@as(u64, 2), event.connection_id);
    try std.testing.expectEqualDeep(Metrics{
        .queued = 0,
        .high_water = 2,
        .dropped = 0,
    }, channel.metrics());
}

test "direct handoff reserves depth before a waiting receiver releases it" {
    var state: GateState = .{};
    var channel: Channel = undefined;
    channel.init(state.gate());
    var receiver = try std.testing.io.concurrent(Channel.receive, .{ &channel, std.testing.io });

    channel.publish(std.testing.io, testEvent(1, 9));
    var event = try receiver.await(std.testing.io);
    defer std.crypto.secureZero(u8, &event.credential.token);

    try std.testing.expectEqual(@as(u64, 9), event.connection_id);
    try std.testing.expectEqualDeep(Metrics{ .queued = 0, .high_water = 1, .dropped = 0 }, channel.metrics());
}

test "closure drains buffered observations then rejects delivery and publication" {
    var state: GateState = .{};
    var channel: Channel = undefined;
    channel.init(state.gate());
    channel.publish(std.testing.io, testEvent(1, 4));
    channel.close(std.testing.io);

    var event = try channel.receive(std.testing.io);
    defer std.crypto.secureZero(u8, &event.credential.token);
    try std.testing.expectEqual(@as(u64, 4), event.connection_id);
    try std.testing.expectError(error.Closed, channel.receive(std.testing.io));

    channel.publish(std.testing.io, testEvent(1, 5));
    try std.testing.expectEqualDeep(Metrics{ .queued = 0, .high_water = 1, .dropped = 1 }, channel.metrics());
}

test "closure wakes a receiver waiting on an empty channel" {
    var state: GateState = .{};
    var channel: Channel = undefined;
    channel.init(state.gate());
    var receiver = try std.testing.io.concurrent(Channel.receive, .{ &channel, std.testing.io });

    channel.close(std.testing.io);

    try std.testing.expectError(error.Closed, receiver.await(std.testing.io));
}
