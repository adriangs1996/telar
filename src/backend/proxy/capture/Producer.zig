const Producer = @This();
const std = @import("std");
const source_namespace = @import("root.zig");
const buffer = @import("buffer_support.zig");
const InitOptions = @import("InitOptions.zig");
const StartOptions = @import("StartOptions.zig");
const Publication = @import("CapturePublication.zig");
const decode_mod = @import("decode.zig");
const Metrics = @import("CaptureMetrics.zig");
gpa: std.mem.Allocator,
config: source_namespace.Config,
quota: buffer.Quota,
channel: source_namespace.Channel = undefined,
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
pub fn start(producer: *Producer, options: StartOptions) ?*source_namespace.Half {
    const half = source_namespace.Half.create(.{
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
pub fn publish(producer: *Producer, io: source_namespace.Io, publication: Publication) void {
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
pub fn receive(producer: *Producer, io: source_namespace.Io) anyerror!*source_namespace.Half {
    return producer.channel.receive(io);
}

/// Closes delivery and frees every half still owned by the queue.
///
/// ```zig
/// producer.close(io);
/// ```
pub fn close(producer: *Producer, io: source_namespace.Io) void {
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
pub fn decodeBody(producer: *Producer, half: *source_namespace.Half) void {
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
    const part: source_namespace.Part = if (half.side == .request) .request_body else .response_body;
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
