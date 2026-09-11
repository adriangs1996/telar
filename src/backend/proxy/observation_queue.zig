//! Bounded delivery channel for proxy observations.

const std = @import("std");
const identity = @import("identity.zig");
const middleware = @import("middleware.zig");

pub const Io = std.Io;

pub const capacity = 256;

pub const CredentialGate = @import("CredentialGate.zig");

pub const Metrics = @import("ObservationQueueMetrics.zig");

pub const Channel = @import("Channel.zig");

const GateState = @import("GateState.zig");

fn testEvent(generation: u64, connection_id: u64) middleware.Event {
    return .{
        .credential = .{
            .pane_id = @enumFromInt(7),
            .pane_generation = generation,
            .token = .{0x5a} ** identity.token_bytes,
        },
        .dialect = .anthropic_messages,
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
