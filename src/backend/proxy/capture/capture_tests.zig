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
    try std.testing.expectEqual(@as(u64, 0), producer.metrics().skipped_quota);
}
