//! Supported namespace for bounded ProxyTLS exchange capture.

const exchangecapture = @import("exchangecapture");
const owned = @import("owned.zig");
const buffer = exchangecapture.buffer_support;
const decode_mod = exchangecapture.decode;
const queue = @import("queue.zig");
const table = owned.Joiner;
const Producer = @import("Producer.zig");
const std = @import("std");

test {
    _ = buffer;
    _ = decode_mod;
    _ = queue;
    _ = table;
}

test "disabled capture does not allocate or reserve quota" {
    var producer: Producer = undefined;
    try producer.init(std.testing.allocator, .{});
    defer producer.close(std.testing.io);

    try std.testing.expect(producer.start(.{
        .protocol = .http11,
        .key = .{ .connection_id = 1, .stream_id = 0 },
        .side = .request,
        .host = "example.test",
        .started_at_ms = 1,
    }) == null);
    try std.testing.expectEqual(@as(usize, 0), producer.quota.used());
    try std.testing.expectEqual(@as(u64, 0), producer.metrics().started);
    try std.testing.expectEqual(@as(u64, 0), producer.metrics().skipped);
}

/// 200 bytes of `a`, gzip-compressed.
const gzip_body = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x13, 0x4b, 0x4c,
    0x1c, 0x1e, 0x00, 0x00, 0x58, 0xf0, 0x9a, 0x59, 0xc8, 0x00, 0x00, 0x00,
};

test "a decoded body cut by the half's share names the exchange bound" {
    var producer: Producer = undefined;
    try producer.init(std.testing.allocator, .{
        .enabled = true,
        .max_part_bytes = 64,
        .max_exchange_bytes = 64,
        .max_total_bytes = 1024,
    });
    defer producer.close(std.testing.io);
    const half = producer.start(.{
        .protocol = .http11,
        .key = .{
            .connection_id = 1,
            .stream_id = 0,
        },
        .side = .response,
        .host = "example.test",
        .started_at_ms = 1,
    }).?;
    defer half.deinit();

    try std.testing.expect(half.append(.response_head, "HEAD"));
    half.setEncoding("gzip");
    try std.testing.expect(half.append(.response_body, &gzip_body));

    producer.decodeBody(half);
    try std.testing.expectEqual(@as(u64, 0), producer.metrics().decode_failed);
    try std.testing.expect(half.body_decoded);
    try std.testing.expectEqual(@as(usize, 28), half.body.len);
    try std.testing.expect(half.truncation.exchange);
    try std.testing.expect(!half.truncation.part);
    try std.testing.expectEqual(@as(u64, 1), producer.metrics().truncated_exchange);
    try std.testing.expectEqual(@as(u64, 0), producer.metrics().truncated_part);
}
