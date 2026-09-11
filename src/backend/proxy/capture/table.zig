//! Runtime-side pairing table for independently published capture halves.

const Exchange = @import("Exchange.zig");
const HalfType = @import("Half.zig");
const QuotaType = @import("Quota.zig");
const buffer = @import("buffer_support.zig");
const CredentialType = @import("../Credential.zig");
const identity = @import("../identity.zig");
const std = @import("std");
const Joiner = @import("Joiner.zig");

pub const capacity = 256;

pub const PushResult = union(enum) {
    pending,
    complete: Exchange,
    partial: Exchange,
};

pub fn sideExchange(half: *HalfType) Exchange {
    return switch (half.side) {
        .request => .{ .request = half },
        .response => .{ .response = half },
    };
}

fn testHalf(quota: *QuotaType, side: buffer.Side) *HalfType {
    const credential: CredentialType = .{
        .pane_id = @enumFromInt(7),
        .pane_generation = 1,
        .token = .{0x5a} ** identity.token_bytes,
    };

    return HalfType.create(.{
        .gpa = std.testing.allocator,
        .quota = quota,
        .config = .{
            .enabled = true,
            .max_part_bytes = 8,
            .max_exchange_bytes = 16,
            .max_total_bytes = 16,
        },
        .credential = credential,
        .dialect = .unknown,
        .protocol = .h2,
        .key = .{ .connection_id = 3, .stream_id = 5 },
        .side = side,
        .host = "example.test",
        .started_at_ms = 1,
    }).?;
}

test "joiner pairs independently delivered request and response halves" {
    var quota = QuotaType.init(16);
    var joiner = Joiner.init(30);
    defer joiner.deinit();

    try std.testing.expectEqual(PushResult.pending, joiner.push(10, testHalf(&quota, .response)));
    var exchange = switch (joiner.push(11, testHalf(&quota, .request))) {
        .complete => |value| value,
        else => return error.ExpectedCompleteCapture,
    };
    defer exchange.deinit();
    try std.testing.expect(exchange.request != null);
    try std.testing.expect(exchange.response != null);
}

test "joiner returns a partial exchange only after its deadline" {
    var quota = QuotaType.init(16);
    var joiner = Joiner.init(30);
    defer joiner.deinit();

    try std.testing.expectEqual(PushResult.pending, joiner.push(10, testHalf(&quota, .request)));
    try std.testing.expect(joiner.expire(39) == null);
    var exchange = joiner.expire(40).?;
    defer exchange.deinit();
    try std.testing.expect(exchange.request != null);
    try std.testing.expect(exchange.response == null);
}
