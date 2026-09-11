//! Supported namespace for bounded ProxyTLS exchange capture.

const std = @import("std");
const buffer = @import("buffer_support.zig");
const decode_mod = @import("decode.zig");
const identity = @import("../identity.zig");
const middleware = @import("../middleware.zig");
const queue = @import("queue.zig");
const table = @import("table.zig");

pub const Io = std.Io;

pub const Buffer = buffer.Buffer;
pub const Channel = queue.Channel;
pub const Config = buffer.Config;
pub const CredentialGate = queue.CredentialGate;
pub const DecodeOptions = decode_mod.Options;
pub const DecodeResult = decode_mod.Result;
pub const decode = decode_mod.decode;
pub const default_join_timeout_ms = buffer.default_join_timeout_ms;
pub const default_max_exchange_bytes = buffer.default_max_exchange_bytes;
pub const default_max_part_bytes = buffer.default_max_part_bytes;
pub const default_max_total_bytes = buffer.default_max_total_bytes;
pub const Exchange = table.Exchange;
pub const Half = buffer.Half;
pub const HalfOptions = buffer.HalfOptions;
pub const Joiner = table.Joiner;
pub const Key = buffer.Key;
pub const Outcome = buffer.Outcome;
pub const Pane = buffer.Pane;
pub const Part = buffer.Part;
pub const PushResult = table.PushResult;
pub const QueueMetrics = queue.Metrics;
pub const Side = buffer.Side;

pub const Metrics = @import("CaptureMetrics.zig");

pub const Producer = @import("Producer.zig");

pub const InitOptions = @import("InitOptions.zig");

pub const StartOptions = @import("StartOptions.zig");

pub const Publication = @import("CapturePublication.zig");

test {
    _ = buffer;
    _ = decode_mod;
    _ = queue;
    _ = table;
}

const TestGate = @import("TestGate.zig");

test "disabled capture does not allocate or reserve quota" {
    var gate_context: u8 = 0;
    var producer: Producer = undefined;
    try producer.init(std.testing.allocator, .{
        .config = .{},
        .gate = .{ .context = &gate_context, .is_live = TestGate.accepts },
    });
    defer producer.close(std.testing.io);
    const credential: identity.Credential = .{
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
