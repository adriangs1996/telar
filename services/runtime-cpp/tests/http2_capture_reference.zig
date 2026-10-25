const std = @import("std");
const http2 = @import("httprelay").http2;
const CaptureStreams = @import("proxy/tunnel/CaptureStreams.zig");
const EventObserver = @import("proxy/tunnel/EventObserver.zig");
const Exchange = @import("proxy/tunnel/Exchange.zig");
const Producer = @import("proxy/capture/Producer.zig");
const Counters = @import("proxy/Counters.zig");
const Half = @import("proxy/capture/owned.zig").Half;
const Session = @import("localca").Session;

const Input = extern struct {
    bytes: [*]const u8,
    length: usize,
    wire: [*]u8,
    events: [*]u8,
    event_capacity: usize,
    fragment: usize,
    fail_after: usize,
    response: u8,
};

const Result = extern struct {
    forwarded: usize,
    consumed: usize,
    events: usize,
    untracked: u32,
    failed: u8,
    block_limit: u8,
    overflow: u8,
};

const MockSession = struct {
    input: *const Input,
    result: *Result,

    pub fn read(self: *@This(), _: Session.Side, destination: []u8) ?usize {
        const count = @min(destination.len, self.input.length - self.result.consumed, self.input.fragment);
        if (count == 0) {
            return null;
        }
        @memcpy(destination[0..count], self.input.bytes[self.result.consumed..][0..count]);
        self.result.consumed += count;
        return count;
    }

    pub fn writeAll(self: *@This(), _: Session.Side, bytes: []const u8) bool {
        if (bytes.len > self.input.fail_after - self.result.forwarded) {
            return false;
        }
        @memcpy(self.input.wire[self.result.forwarded..][0..bytes.len], bytes);
        self.result.forwarded += bytes.len;
        return true;
    }

    pub fn halfClose(_: *@This(), _: Session.Side) void {}
};

const Output = struct {
    input: *const Input,
    result: *Result,

    fn integer(self: *@This(), value: u64, size: usize) void {
        var bytes: [8]u8 = undefined;
        for (0..size) |index| {
            bytes[index] = @truncate(value >> @as(u6, @intCast(8 * index)));
        }
        self.append(bytes[0..size]);
    }

    fn text(self: *@This(), value: []const u8) void {
        self.integer(value.len, 8);
        self.append(value);
    }

    fn append(self: *@This(), bytes: []const u8) void {
        if (bytes.len > self.input.event_capacity - self.result.events) {
            self.result.overflow = 1;
            return;
        }
        @memcpy(self.input.events[self.result.events..][0..bytes.len], bytes);
        self.result.events += bytes.len;
    }
};

fn writeHalf(output: *Output, half: *const Half) void {
    for ([_]u64{ half.key.connection_id, half.key.stream_id, @intFromEnum(half.side), @intFromBool(half.meta.protocol == .h2), half.status_code, @intFromEnum(half.outcome), @intFromBool(half.head.truncated), @intFromBool(half.body.truncated), @intFromBool(half.body_decoded), @intFromBool(half.truncation.part), @intFromBool(half.truncation.exchange), @intFromBool(half.truncation.total) }) |value| {
        output.integer(value, 8);
    }
    output.text(half.host());
    output.text(half.method());
    output.text(half.target());
    output.text(half.encoding());
    output.text(half.head.bytes());
    output.text(half.body.bytes());
}

export fn relay(input: *const Input, result: *Result) void {
    result.* = std.mem.zeroes(Result);
    var session = MockSession{ .input = input, .result = result };
    const io = std.Io.Threaded.global_single_threaded.io();
    var producer: Producer = undefined;
    producer.init(std.heap.c_allocator, .{ .enabled = true }) catch unreachable;
    defer producer.close(io);
    var counters: Counters = .{};
    var exchange: Exchange = .{ .io = io, .telemetry = &counters, .connection_id = 31, .protocol = .h2, .host = .{ .bytes = "example.test" } };
    var captures: CaptureStreams = .{ .producer = &producer, .exchange = &exchange, .side = if (input.response != 0) .response else .request };
    var observer: EventObserver = .{ .captures = &captures, .exchange = &exchange };
    const options = http2.relayOptions(if (input.response != 0) .response else .request, .{ .gpa = std.heap.c_allocator });
    const stats = http2.relay(&session, options, &observer);
    result.failed = @intFromBool(stats.decode_failed);
    result.block_limit = @intFromBool(stats.header_block_too_large);
    result.untracked = stats.untracked_streams;
    captures.deinit();
    var output: Output = .{ .input = input, .result = result };
    const metrics = producer.metrics();
    for ([_]u64{ metrics.started, metrics.truncated, metrics.truncated_part, metrics.truncated_exchange, metrics.truncated_total, metrics.skipped, metrics.decode_failed, metrics.dropped_queue, metrics.queued, metrics.queue_high_water, counters.values.getPtr(.h2_capture_stream_skipped).load(.monotonic) }) |value| {
        output.integer(value, 8);
    }
    while (producer.channel.halves.tryReceive(io)) |half| {
        writeHalf(&output, half);
        half.deinit();
    }
    output.integer(producer.quota.used(), 8);
}

export fn batch(input: *const Input, iterations: usize) u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        var result: Result = undefined;
        relay(input, &result);
        checksum += result.forwarded + result.consumed + result.events + result.untracked + result.failed + result.block_limit;
    }
    return checksum;
}
