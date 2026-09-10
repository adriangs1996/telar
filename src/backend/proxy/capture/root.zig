//! Supported namespace for bounded ProxyTLS exchange capture.

const std = @import("std");
const buffer = @import("buffer.zig");
const decode_mod = @import("decode.zig");
const identity = @import("../identity.zig");
const middleware = @import("../middleware.zig");
const queue = @import("queue.zig");
const table = @import("table.zig");

const Io = std.Io;

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

pub const Metrics = struct {
    started: u64 = 0,
    truncated: u64 = 0,
    skipped_quota: u64 = 0,
    dropped_queue: u64 = 0,
    decode_failed: u64 = 0,
    queued: u64 = 0,
    queue_high_water: u64 = 0,
};

pub const Producer = struct {
    gpa: std.mem.Allocator,
    config: Config,
    quota: buffer.Quota,
    channel: Channel = undefined,
    started: std.atomic.Value(u64) = .init(0),
    truncated: std.atomic.Value(u64) = .init(0),
    skipped_quota: std.atomic.Value(u64) = .init(0),
    decode_failed: std.atomic.Value(u64) = .init(0),

    /// Initializes bounded capture storage and its credential-gated queue.
    ///
    /// ```zig
    /// try producer.init(gpa, .{ .config = config, .gate = gate });
    /// ```
    pub fn init(producer: *Producer, gpa: std.mem.Allocator, options: InitOptions) !void {
        try options.config.validate();
        producer.* = .{
            .gpa = gpa,
            .config = options.config,
            .quota = .init(options.config.max_total_bytes),
        };
        producer.channel.init(options.gate);
    }

    /// Reserves one direction of an exchange without blocking the relay.
    ///
    /// ```zig
    /// const half = producer.start(options) orelse return;
    /// ```
    pub fn start(producer: *Producer, options: StartOptions) ?*Half {
        const half = Half.create(.{
            .gpa = producer.gpa,
            .quota = &producer.quota,
            .config = producer.config,
            .credential = options.credential,
            .dialect = options.dialect,
            .protocol = options.protocol,
            .key = options.key,
            .side = options.side,
            .host = options.host,
            .started_at_ms = options.started_at_ms,
        }) orelse {
            if (producer.config.enabled) {
                _ = producer.skipped_quota.fetchAdd(1, .monotonic);
            }

            return null;
        };

        if (options.side == .request) {
            _ = producer.started.fetchAdd(1, .monotonic);
        }

        return half;
    }

    /// Transfers a finished half to the runtime or frees it when delivery fails.
    ///
    /// ```zig
    /// producer.publish(io, .{ .credential = credential, .half = half });
    /// ```
    pub fn publish(producer: *Producer, io: Io, publication: Publication) void {
        if (publication.half.head.truncated or publication.half.body.truncated) {
            _ = producer.truncated.fetchAdd(1, .monotonic);
        }

        _ = producer.channel.publish(io, .{
            .credential = publication.credential,
            .half = publication.half,
        });
    }

    /// Waits for one half whose pane credential is still live.
    ///
    /// ```zig
    /// const half = try producer.receive(io);
    /// ```
    pub fn receive(producer: *Producer, io: Io) anyerror!*Half {
        return producer.channel.receive(io);
    }

    /// Closes delivery and frees every half still owned by the queue.
    ///
    /// ```zig
    /// producer.close(io);
    /// ```
    pub fn close(producer: *Producer, io: Io) void {
        producer.channel.close(io);
    }

    /// Records one body that could not be decoded without retaining its data.
    ///
    /// ```zig
    /// producer.recordDecodeFailure();
    /// ```
    pub fn recordDecodeFailure(producer: *Producer) void {
        _ = producer.decode_failed.fetchAdd(1, .monotonic);
    }

    /// Replaces a content-coded body with its bounded decoded representation.
    ///
    /// ```zig
    /// producer.decodeBody(half);
    /// ```
    pub fn decodeBody(producer: *Producer, half: *Half) void {
        if (half.encoding().len == 0 or std.ascii.eqlIgnoreCase(half.encoding(), "identity")) {
            half.body_decoded = true;
            return;
        }

        const available = @min(producer.config.max_part_bytes, half.reservation.bytes -| half.head.len);
        if (available == 0) {
            half.body.truncated = half.body.len != 0;
            return;
        }

        var result = decode_mod.decode(producer.gpa, .{
            .input = half.body.bytes(),
            .encoding = half.encoding(),
            .max_bytes = available,
        }) catch {
            producer.recordDecodeFailure();
            return;
        };
        defer result.deinit(producer.gpa);
        if (result.failed) {
            producer.recordDecodeFailure();
            return;
        }

        const was_truncated = half.body.truncated;
        half.captured_bytes -= half.body.len;
        half.body.reset();
        const part: Part = if (half.side == .request) .request_body else .response_body;
        _ = half.append(part, result.bytes);
        half.body.truncated = half.body.truncated or result.truncated or was_truncated;
        half.body_decoded = result.decoded;
        if (!was_truncated and half.body.truncated) {
            _ = producer.truncated.fetchAdd(1, .monotonic);
        }
    }

    /// Returns current atomic counters and queue depth as one value snapshot.
    ///
    /// ```zig
    /// const snapshot = producer.metrics();
    /// ```
    pub fn metrics(producer: *const Producer) Metrics {
        const queue_metrics = producer.channel.metrics();

        return .{
            .started = producer.started.load(.monotonic),
            .truncated = producer.truncated.load(.monotonic),
            .skipped_quota = producer.skipped_quota.load(.monotonic),
            .dropped_queue = queue_metrics.dropped,
            .decode_failed = producer.decode_failed.load(.monotonic),
            .queued = queue_metrics.queued,
            .queue_high_water = queue_metrics.high_water,
        };
    }
};

pub const InitOptions = struct {
    config: Config,
    gate: CredentialGate,
};

pub const StartOptions = struct {
    credential: identity.Credential,
    dialect: middleware.ApiDialect,
    protocol: middleware.Protocol,
    key: Key,
    side: Side,
    host: []const u8,
    started_at_ms: i64,
};

pub const Publication = struct {
    credential: identity.Credential,
    half: *Half,
};

test {
    _ = buffer;
    _ = decode_mod;
    _ = queue;
    _ = table;
}

const TestGate = struct {
    fn accepts(_: *anyopaque, _: *const identity.Credential) bool {
        return true;
    }
};

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
