const head = @import("http1/head_support.zig");
const std = @import("std");
const Result = extern struct { length: u64, kind: u32, status: u16, flags: u8, valid: u8 };
export fn analyze(bytes: [*]const u8, length: usize, flags: u8, result: *Result) void {
    result.* = .{ .length = 0, .kind = 0, .status = 0, .flags = 0, .valid = 0 };
    const parsed = head.analyze(bytes[0..length], .{ .is_response = flags & 1 != 0, .response_to_head = flags & 2 != 0 }) orelse return;
    result.valid = 1;
    result.status = parsed.message.status_code;
    result.flags = @as(u8, @intFromBool(parsed.message.head_request)) | (@as(u8, @intFromBool(parsed.message.informational)) << 1) | (@as(u8, @intFromBool(parsed.message.upgrade)) << 2) | (@as(u8, @intFromBool(parsed.message.closes)) << 3);
    switch (parsed.framing) {
        .none => {},
        .content_length => |count| {
            result.kind = 1;
            result.length = count;
        },
        .chunked => result.kind = 2,
        .until_close => result.kind = 3,
    }
}
export fn number(bytes: [*]const u8, length: usize, base: u8, result: *u64) bool {
    result.* = std.fmt.parseInt(usize, bytes[0..length], base) catch return false;
    return true;
}
const http = @import("http1/http1.zig");
const Session = @import("localca").Session;
const Input = extern struct { bytes: [*]const u8, length: usize, output: [*]u8, payload: [*]u8, capacity: usize, fragment: usize, flags: u8 };
const RelayResult = extern struct { forwarded: usize, payload: usize, consumed: usize, heads: usize, head_limits: usize, chunk_limits: usize, trailer_limits: usize, valid: u8 };
const MockSession = struct {
    input: *const Input,
    result: *RelayResult,
    pub fn read(self: *@This(), _: Session.Side, destination: []u8) ?usize {
        const count = @min(destination.len, self.input.length - self.result.consumed, self.input.fragment);
        if (count == 0) return null;
        @memcpy(destination[0..count], self.input.bytes[self.result.consumed..][0..count]);
        self.result.consumed += count;
        return count;
    }
    pub fn writeAll(self: *@This(), _: Session.Side, bytes: []const u8) bool {
        if (bytes.len > self.input.capacity - self.result.forwarded) return false;
        @memcpy(self.input.output[self.result.forwarded..][0..bytes.len], bytes);
        self.result.forwarded += bytes.len;
        return true;
    }
};
const Observer = struct {
    input: *const Input,
    result: *RelayResult,
    pub fn headStarted(self: *@This()) void {
        self.result.heads += 1;
    }
    pub fn head(_: *@This(), _: []const u8) void {}
    pub fn headTooLarge(self: *@This()) void {
        self.result.head_limits += 1;
    }
    pub fn observe(self: *@This(), fragment: http.Fragment) void {
        std.debug.assert(fragment.payload.len <= self.input.capacity - self.result.payload);
        @memcpy(self.input.payload[self.result.payload..][0..fragment.payload.len], fragment.payload);
        self.result.payload += fragment.payload.len;
    }
    pub fn lineTooLong(self: *@This(), kind: http.FramingLine) void {
        switch (kind) {
            .chunk_size => self.result.chunk_limits += 1,
            .trailer => self.result.trailer_limits += 1,
        }
    }
};
export fn relay(input: *const Input, result: *RelayResult) void {
    result.* = std.mem.zeroes(RelayResult);
    var session = MockSession{ .input = input, .result = result };
    var observer = Observer{ .input = input, .result = result };
    const message = http.relay(&session, .{ .from = .child, .to = .origin, .is_response = input.flags & 1 != 0, .response_to_head = input.flags & 2 != 0 }, &observer);
    result.valid = @intFromBool(message != null);
}

export fn batch(input: *const Input, iterations: usize) u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        var result: RelayResult = undefined;
        relay(input, &result);
        checksum += result.forwarded + result.payload + result.consumed + result.valid;
    }
    return checksum;
}
