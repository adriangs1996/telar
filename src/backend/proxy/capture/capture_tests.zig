//! Supported namespace for bounded ProxyTLS exchange capture.

const buffer = @import("buffer_support.zig");
const decode_mod = @import("decode.zig");
const queue = @import("queue.zig");
const table = @import("table.zig");
const Producer = @import("Producer.zig");
const std = @import("std");
const TestGate = @import("TestGate.zig");
const CredentialType = @import("../Credential.zig");
const identity = @import("../identity.zig");

test {
    _ = buffer;
    _ = decode_mod;
    _ = queue;
    _ = table;
}

test "disabled capture does not allocate or reserve quota" {
    var gate_context: u8 = 0;
    var producer: Producer = undefined;
    try producer.init(std.testing.allocator, .{
        .config = .{},
        .gate = .{ .context = &gate_context, .is_live = TestGate.accepts },
    });
    defer producer.close(std.testing.io);
    const credential: CredentialType = .{
        .pane_id = @enumFromInt(1),
        .pane_generation = 1,
        .token = .{0x5a} ** identity.token_bytes,
    };

    try std.testing.expect(producer.start(.{
        .credential = credential,
        .dialect = .unknown,
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
