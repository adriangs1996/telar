const exchangecapture = @import("exchangecapture");
const owned = @import("owned.zig");
const std = @import("std");
const Config = exchangecapture.Config;
const Quota = exchangecapture.Quota;
const Channel = @import("Channel.zig");
const StartOptions = @import("StartOptions.zig");
const Half = owned.Half;
const decode_mod = exchangecapture.decode;
const buffer = exchangecapture.buffer_support;
const CaptureMetrics = @import("CaptureMetrics.zig");
const Truncation = exchangecapture.Truncation;
const Producer = @This();

gpa: std.mem.Allocator,
config: Config,
quota: Quota,
channel: Channel = undefined,
started: std.atomic.Value(u64) = .init(0),
truncated: std.atomic.Value(u64) = .init(0),
/// Halves cut short by `max_part_bytes`, by their share of
/// `max_exchange_bytes` and by `max_total_bytes`; a half counts once per
/// bound that cut it.
truncated_part: std.atomic.Value(u64) = .init(0),
truncated_exchange: std.atomic.Value(u64) = .init(0),
truncated_total: std.atomic.Value(u64) = .init(0),
/// Directions not captured because their half could not be allocated.
skipped: std.atomic.Value(u64) = .init(0),
decode_failed: std.atomic.Value(u64) = .init(0),

/// Initializes bounded capture storage and its delivery queue.
///
/// ```zig
/// try producer.init(gpa, config);
/// ```
pub fn init(self: *Producer, gpa: std.mem.Allocator, config: Config) !void {
    try config.validate();
    self.* = .{
        .gpa = gpa,
        .config = config,
        .quota = .init(config.max_total_bytes),
    };
    self.channel.init();
}

/// Starts one direction of an exchange without blocking the relay. The half
/// reserves quota only as bytes arrive.
///
/// ```zig
/// const half = producer.start(options) orelse return;
/// ```
pub fn start(self: *Producer, options: StartOptions) ?*Half {
    const half = Half.create(.{
        .gpa = self.gpa,
        .quota = &self.quota,
        .config = self.config,
        .meta = .{ .protocol = options.protocol },
        .key = options.key,
        .side = options.side,
        .host = options.host,
        .started_at_ms = options.started_at_ms,
    }) orelse {
        if (self.config.enabled) {
            _ = self.skipped.fetchAdd(1, .monotonic);
        }

        return null;
    };

    if (options.side == .request) {
        _ = self.started.fetchAdd(1, .monotonic);
    }

    return half;
}

/// Transfers a finished half to the runtime or frees it when delivery fails.
///
/// ```zig
/// producer.publish(io, half);
/// ```
pub fn publish(self: *Producer, io: std.Io, half: *Half) void {
    if (half.head.truncated or half.body.truncated) {
        _ = self.truncated.fetchAdd(1, .monotonic);
    }

    self.countTruncation(half.truncation);
    _ = self.channel.publish(io, half);
}

fn countTruncation(self: *Producer, truncation: Truncation) void {
    if (truncation.part) {
        _ = self.truncated_part.fetchAdd(1, .monotonic);
    }

    if (truncation.exchange) {
        _ = self.truncated_exchange.fetchAdd(1, .monotonic);
    }

    if (truncation.total) {
        _ = self.truncated_total.fetchAdd(1, .monotonic);
    }
}

/// Waits for one captured half.
///
/// ```zig
/// const half = try producer.receive(io);
/// ```
pub fn receive(self: *Producer, io: std.Io) anyerror!*Half {
    return self.channel.receive(io);
}

/// Closes delivery and frees every half still owned by the queue.
///
/// ```zig
/// producer.close(io);
/// ```
pub fn close(self: *Producer, io: std.Io) void {
    self.channel.close(io);
}

/// Records one body that could not be decoded without retaining its data.
///
/// ```zig
/// producer.recordDecodeFailure();
/// ```
pub fn recordDecodeFailure(self: *Producer) void {
    _ = self.decode_failed.fetchAdd(1, .monotonic);
}

/// Replaces a content-coded body with its bounded decoded representation.
///
/// ```zig
/// producer.decodeBody(half);
/// ```
pub fn decodeBody(self: *Producer, half: *Half) void {
    if (half.encoding().len == 0 or std.ascii.eqlIgnoreCase(half.encoding(), "identity")) {
        half.body_decoded = true;
        return;
    }

    const available = @min(self.config.max_part_bytes, half.max_bytes -| half.head.len);
    if (available == 0) {
        half.body.truncated = half.body.len != 0;
        return;
    }

    var result = decode_mod.decode(self.gpa, .{
        .input = half.body.bytes(),
        .encoding = half.encoding(),
        .max_bytes = available,
    }) catch {
        self.recordDecodeFailure();
        return;
    };
    defer result.deinit(self.gpa);
    if (result.failed) {
        self.recordDecodeFailure();
        return;
    }

    const was_truncated = half.body.truncated;
    const cut_before = half.truncation;
    half.captured_bytes -= half.body.len;
    half.body.reset();
    const part: buffer.Part = if (half.side == .request) .request_body else .response_body;
    _ = half.append(part, result.bytes);
    if (result.truncated) {
        half.truncation.part = true;
    }

    half.body.truncated = half.body.truncated or result.truncated or was_truncated;
    half.body_decoded = result.decoded;
    if (!was_truncated and half.body.truncated) {
        _ = self.truncated.fetchAdd(1, .monotonic);
    }

    self.countTruncation(.{
        .part = half.truncation.part and !cut_before.part,
        .exchange = half.truncation.exchange and !cut_before.exchange,
        .total = half.truncation.total and !cut_before.total,
    });
}

/// Returns current atomic counters and queue depth as one value snapshot.
///
/// ```zig
/// const snapshot = producer.metrics();
/// ```
pub fn metrics(self: *const Producer) CaptureMetrics {
    const queue_metrics = self.channel.metrics();

    return .{
        .started = self.started.load(.monotonic),
        .truncated = self.truncated.load(.monotonic),
        .truncated_part = self.truncated_part.load(.monotonic),
        .truncated_exchange = self.truncated_exchange.load(.monotonic),
        .truncated_total = self.truncated_total.load(.monotonic),
        .skipped = self.skipped.load(.monotonic),
        .dropped_queue = queue_metrics.dropped,
        .decode_failed = self.decode_failed.load(.monotonic),
        .queued = queue_metrics.queued,
        .queue_high_water = queue_metrics.high_water,
    };
}
