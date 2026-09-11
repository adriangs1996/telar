//! Bounded pointer-transfer queue for captured exchange halves.

const std = @import("std");
const buffer = @import("buffer_support.zig");
const identity = @import("../identity.zig");

pub const Io = std.Io;

pub const capacity = 256;

pub const CredentialGate = @import("CredentialGate.zig");

pub const Metrics = @import("QueueMetrics.zig");

const Envelope = @import("Envelope.zig");

pub const Publication = @import("QueuePublication.zig");

pub const Channel = @import("Channel.zig");

const GateState = @import("GateState.zig");

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
