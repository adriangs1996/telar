//! Bounded, scrubbed storage for one captured exchange part.

const Buffer = @import("Buffer.zig");
const std = @import("std");
const Quota = @import("Quota.zig");
const Config = @import("Config.zig");

pub const max_host_bytes = 255;
pub const max_method_bytes = 32;
pub const max_target_bytes = 8 * 1024;
pub const max_encoding_bytes = 128;

pub const Part = enum {
    request_head,
    request_body,
    response_head,
    response_body,
};

pub const Side = enum {
    request,
    response,
};

pub const Outcome = enum {
    finished,
    failed,
    reset,
};

test "buffer grows within its bound and scrubs owned storage" {
    var buffer = Buffer.init(std.testing.allocator, 5);
    defer buffer.deinit();

    try std.testing.expect(buffer.append("abc"));
    try std.testing.expect(!buffer.append("def"));
    try std.testing.expectEqualStrings("abcde", buffer.bytes());
    try std.testing.expect(buffer.truncated);
}

test "quota reservations remain bounded and release exactly once" {
    var quota = Quota.init(8);
    var first = quota.reserve(5).?;
    try std.testing.expect(quota.reserve(4) == null);
    var second = quota.reserve(3).?;
    try std.testing.expectEqual(@as(usize, 8), quota.used());

    first.release();
    second.release();
    second.release();
    try std.testing.expectEqual(@as(usize, 0), quota.used());
}

test "capture config rejects impossible bounds" {
    try (Config{}).validate();
    try std.testing.expectError(error.InvalidCaptureQuota, (Config{ .max_part_bytes = 9, .max_exchange_bytes = 8 }).validate());
    try std.testing.expectError(error.InvalidCaptureQuota, (Config{ .max_exchange_bytes = 9, .max_total_bytes = 8 }).validate());
    try std.testing.expectError(error.InvalidCaptureTimeout, (Config{ .join_timeout_ms = 0 }).validate());
}
