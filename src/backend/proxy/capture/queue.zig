//! Bounded pointer-transfer queue for captured exchange halves.

const exchangecapture = @import("exchangecapture");
const owned = @import("owned.zig");
const Credential = @import("../Credential.zig");
const identity = @import("../identity.zig");
const Quota = exchangecapture.Quota;
const Half = owned.Half;
const std = @import("std");
const Channel = @import("Channel.zig");
const Registry = @import("../Registry.zig");
const CredentialId = @import("../CredentialId.zig");

pub const capacity = 256;

fn testCredential(generation: u64) Credential {
    return .{
        .pane_id = @enumFromInt(7),
        .pane_generation = generation,
        .token = .{0x5a} ** identity.token_bytes,
    };
}

/// A registry where generation 1 of the test pane is live.
fn liveRegistry() !Registry {
    var registry: Registry = .{};
    try registry.register(std.testing.io, &testCredential(1));
    return registry;
}

fn testHalf(quota: *Quota, owner: CredentialId, stream_id: u32) *Half {
    return Half.create(.{
        .gpa = std.testing.allocator,
        .quota = quota,
        .config = .{
            .enabled = true,
            .max_part_bytes = 1,
            .max_exchange_bytes = 2,
            .max_total_bytes = capacity + 1,
        },
        .meta = .{
            .pane = .{
                .id = owner.pane_id,
                .generation = owner.pane_generation,
            },
            .dialect = .unknown,
            .protocol = .h2,
        },
        .key = .{ .connection_id = 1, .stream_id = stream_id },
        .side = .request,
        .host = "example.test",
        .started_at_ms = 1,
    }).?;
}

test "queue saturation drops and frees the rejected half" {
    var registry = try liveRegistry();
    var channel: Channel = undefined;
    channel.init(&registry);
    var quota = Quota.init(capacity + 1);
    const owner = registry.identify(std.testing.io, &testCredential(1)).?;

    for (0..capacity) |index| {
        try std.testing.expect(channel.publish(std.testing.io, .{
            .owner = owner,
            .half = testHalf(&quota, owner, @intCast(index + 1)),
        }));
    }
    try std.testing.expect(!channel.publish(std.testing.io, .{
        .owner = owner,
        .half = testHalf(&quota, owner, capacity + 1),
    }));
    try std.testing.expectEqual(@as(usize, capacity), quota.used());
    try std.testing.expectEqual(@as(u64, 1), channel.metrics().dropped);

    channel.close(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), quota.used());
    try std.testing.expectEqual(@as(u64, 0), channel.metrics().queued);
}

test "delivery rejects a credential revoked after publication" {
    var registry = try liveRegistry();
    var channel: Channel = undefined;
    channel.init(&registry);
    defer channel.close(std.testing.io);
    var quota = Quota.init(2);
    const owner = registry.identify(std.testing.io, &testCredential(1)).?;
    try std.testing.expect(channel.publish(std.testing.io, .{
        .owner = owner,
        .half = testHalf(&quota, owner, 1),
    }));

    registry.removePane(std.testing.io, .{ .id = @enumFromInt(7), .generation = 1 });
    channel.close(std.testing.io);
    try std.testing.expectError(error.Closed, channel.receive(std.testing.io));
    try std.testing.expectEqual(@as(usize, 0), quota.used());
}
