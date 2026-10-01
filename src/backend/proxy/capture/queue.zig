//! Bounded pointer-transfer queue for captured exchange halves.

const core = @import("telar-core");
const exchangecapture = @import("exchangecapture");
const owned = @import("owned.zig");
const Quota = exchangecapture.Quota;
const Half = owned.Half;
const std = @import("std");
const Channel = @import("Channel.zig");

pub const capacity = 256;
pub const capacity_limit = core.Limit.declare("proxy.capture.queue_capacity", "halves", capacity);

/// A half holding one captured byte of the quota.
fn testHalf(quota: *Quota, stream_id: u32) *Half {
    const half = Half.create(.{
        .gpa = std.testing.allocator,
        .quota = quota,
        .config = .{
            .enabled = true,
            .max_part_bytes = 1,
            .max_exchange_bytes = 2,
            .max_total_bytes = capacity + 1,
        },
        .meta = .{ .protocol = .h2 },
        .key = .{ .connection_id = 1, .stream_id = stream_id },
        .side = .request,
        .host = "example.test",
        .started_at_ms = 1,
    }).?;
    std.debug.assert(half.append(.request_body, "x"));
    return half;
}

test "queue saturation drops and frees the rejected half" {
    var channel: Channel = undefined;
    channel.init();
    var quota = Quota.init(capacity + 1);

    for (0..capacity) |index| {
        try std.testing.expect(channel.publish(std.testing.io, testHalf(&quota, @intCast(index + 1))));
    }
    try std.testing.expect(!channel.publish(std.testing.io, testHalf(&quota, capacity + 1)));
    try std.testing.expectEqual(@as(usize, capacity), quota.used());
    try std.testing.expectEqual(@as(u64, 1), channel.metrics().dropped);

    channel.close(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), quota.used());
    try std.testing.expectEqual(@as(u64, 0), channel.metrics().queued);
}

test "closing frees the halves still queued" {
    var channel: Channel = undefined;
    channel.init();
    var quota = Quota.init(2);
    try std.testing.expect(channel.publish(std.testing.io, testHalf(&quota, 1)));

    channel.close(std.testing.io);
    try std.testing.expectError(error.Closed, channel.receive(std.testing.io));
    try std.testing.expectEqual(@as(usize, 0), quota.used());
}
