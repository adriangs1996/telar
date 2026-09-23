const std = @import("std");
const Config = @import("Config.zig");
const Quota = @import("Quota.zig");
const Channel = @import("Channel.zig");
const CredentialGate = @import("../CredentialGate.zig");
const StartOptions = @import("StartOptions.zig");
const Half = @import("Half.zig");
const CapturePublication = @import("CapturePublication.zig");
const decode_mod = @import("decode.zig");
const buffer = @import("buffer_support.zig");
const CaptureMetrics = @import("CaptureMetrics.zig");
const Producer = @This();

gpa: std.mem.Allocator,
config: Config,
quota: Quota,
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
pub fn init(self: *Producer, gpa: std.mem.Allocator, options: InitOptions) !void {
    try options.config.validate();
    self.* = .{
        .gpa = gpa,
        .config = options.config,
        .quota = .init(options.config.max_total_bytes),
    };
    self.channel.init(options.gate);
}

/// Reserves one direction of an exchange without blocking the relay.
///
/// ```zig
/// const half = producer.start(options) orelse return;
/// ```
pub fn start(self: *Producer, options: StartOptions) ?*Half {
    const half = Half.create(.{
        .gpa = self.gpa,
        .quota = &self.quota,
        .config = self.config,
        .credential = options.credential,
        .dialect = options.dialect,
        .protocol = options.protocol,
        .key = options.key,
        .side = options.side,
        .host = options.host,
        .started_at_ms = options.started_at_ms,
    }) orelse {
        if (self.config.enabled) {
            _ = self.skipped_quota.fetchAdd(1, .monotonic);
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
/// producer.publish(io, .{ .credential = credential, .half = half });
/// ```
pub fn publish(self: *Producer, io: std.Io, publication: CapturePublication) void {
    if (publication.half.head.truncated or publication.half.body.truncated) {
        _ = self.truncated.fetchAdd(1, .monotonic);
    }

    _ = self.channel.publish(io, .{
        .credential = publication.credential,
        .half = publication.half,
    });
}

/// Waits for one half whose pane credential is still live.
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

    const available = @min(self.config.max_part_bytes, half.reservation.bytes -| half.head.len);
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
    half.captured_bytes -= half.body.len;
    half.body.reset();
    const part: buffer.Part = if (half.side == .request) .request_body else .response_body;
    _ = half.append(part, result.bytes);
    half.body.truncated = half.body.truncated or result.truncated or was_truncated;
    half.body_decoded = result.decoded;
    if (!was_truncated and half.body.truncated) {
        _ = self.truncated.fetchAdd(1, .monotonic);
    }
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
        .skipped_quota = self.skipped_quota.load(.monotonic),
        .dropped_queue = queue_metrics.dropped,
        .decode_failed = self.decode_failed.load(.monotonic),
        .queued = queue_metrics.queued,
        .queue_high_water = queue_metrics.high_water,
    };
}

const InitOptions = struct {
    config: Config,
    gate: CredentialGate,
};
