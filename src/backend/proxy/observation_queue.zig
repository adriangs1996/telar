//! Bounded delivery channel for proxy observations.

const dropqueue = @import("dropqueue");
const MiddlewareEvent = @import("MiddlewareEvent.zig");
const identity = @import("identity.zig");
const std = @import("std");
const Credential = @import("Credential.zig");
const Registry = @import("Registry.zig");
const CredentialId = @import("CredentialId.zig");
const QueueMetrics = dropqueue.QueueMetrics;

pub const capacity = 256;

pub const Channel = @import("Channel.zig");

fn testCredential(generation: u64) Credential {
    return .{
        .pane_id = @enumFromInt(7),
        .pane_generation = generation,
        .token = .{0x5a} ** identity.token_bytes,
    };
}

/// A registry where only `generation` of the test pane is live.
fn liveRegistry(generation: u64) !Registry {
    var registry: Registry = .{};
    try registry.register(std.testing.io, &testCredential(generation));
    return registry;
}

/// Revokes the live generation and makes `next` live instead.
fn replaceGeneration(registry: *Registry, revoked: u64, next: u64) !void {
    registry.removePane(std.testing.io, .{ .id = @enumFromInt(7), .generation = revoked });
    try registry.register(std.testing.io, &testCredential(next));
}

/// The identity of the test pane's credential for `generation`; one never
/// registered carries a serial the registry has not issued.
fn testOwner(registry: *Registry, generation: u64) CredentialId {
    return registry.identify(std.testing.io, &testCredential(generation)) orelse .{
        .pane_id = @enumFromInt(7),
        .pane_generation = generation,
        .serial = registry.next_serial,
    };
}

fn testEvent(owner: CredentialId, connection_id: u64) MiddlewareEvent {
    return .{
        .owner = owner,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .protocol = .http11,
        .connection_id = connection_id,
        .observed_at_ms = 1,
    };
}

test "publication rejects revoked credentials without consuming capacity" {
    var registry = try liveRegistry(1);
    var channel: Channel = undefined;
    channel.init(&registry);

    channel.publish(std.testing.io, testEvent(testOwner(&registry, 2), 1));

    try std.testing.expectEqualDeep(QueueMetrics{ .queued = 0, .high_water = 0, .dropped = 0 }, channel.metrics());
}

test "delivery discards events revoked after publication" {
    var registry = try liveRegistry(1);
    var channel: Channel = undefined;
    channel.init(&registry);

    channel.publish(std.testing.io, testEvent(testOwner(&registry, 1), 1));
    try replaceGeneration(&registry, 1, 2);
    channel.publish(std.testing.io, testEvent(testOwner(&registry, 2), 2));

    const event = try channel.receive(std.testing.io);

    try std.testing.expectEqual(@as(u64, 2), event.connection_id);
    try std.testing.expectEqualDeep(QueueMetrics{
        .queued = 0,
        .high_water = 2,
        .dropped = 0,
    }, channel.metrics());
}
