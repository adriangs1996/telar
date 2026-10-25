const std = @import("std");
const http2 = @import("http2/relay.zig");
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

const Observer = struct {
    input: *const Input,
    result: *Result,

    pub fn emit(self: *@This(), event: http2.Event) void {
        switch (event) {
            .lifecycle => |value| self.record(.{ .kind = @intFromEnum(value.stage), .stream = value.stream_id, .status = value.status_code }),
            .request_headers, .response_headers => |value| {
                for (value.fields) |field| {
                    self.record(.{ .kind = if (event == .request_headers) 5 else 6, .stream = value.stream_id, .name = field.name, .value = field.value });
                }
            },
            .request_body => |value| self.record(.{ .kind = 7, .stream = value.stream_id, .bytes = value.bytes }),
            .response_body => |value| self.record(.{ .kind = 8, .stream = value.stream_id, .status = value.status_code, .sse = value.sse_body, .bytes = value.bytes }),
            .request_finished => |value| self.record(.{ .kind = 9, .stream = value.stream_id }),
        }
    }

    const Record = struct {
        kind: u8,
        stream: u32 = 0,
        status: u16 = 0,
        sse: bool = false,
        name: []const u8 = "",
        value: []const u8 = "",
        bytes: []const u8 = "",
    };

    fn record(self: *@This(), value: Record) void {
        self.integer(value.kind, 1);
        self.integer(value.stream, 4);
        self.integer(value.status, 2);
        self.integer(@intFromBool(value.sse), 1);
        self.text(value.name);
        self.text(value.value);
        self.text(value.bytes);
    }

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

export fn relay(input: *const Input, result: *Result) void {
    result.* = std.mem.zeroes(Result);
    var session = MockSession{ .input = input, .result = result };
    var observer = Observer{ .input = input, .result = result };
    const stats = http2.relay(&session, .{
        .from = if (input.response != 0) .origin else .child,
        .to = if (input.response != 0) .child else .origin,
        .direction = if (input.response != 0) .response else .request,
        .gpa = std.heap.c_allocator,
    }, &observer);
    result.failed = @intFromBool(stats.decode_failed);
    result.block_limit = @intFromBool(stats.header_block_too_large);
    result.untracked = stats.untracked_streams;
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
