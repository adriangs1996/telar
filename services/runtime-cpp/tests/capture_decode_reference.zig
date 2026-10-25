const std = @import("std");
const capture = @import("capture");

const Input = extern struct {
    bytes: [*]const u8,
    length: usize,
    encoding: [*]const u8,
    encoding_length: usize,
    limit: usize,
    output: [*]u8,
};

const Result = extern struct {
    length: usize,
    decoded: u8,
    truncated: u8,
    failed: u8,
    err: u8,
};

export fn decode(input: *const Input, result: *Result) void {
    result.* = std.mem.zeroes(Result);
    var decoded = capture.decode.decode(std.heap.c_allocator, .{
        .input = input.bytes[0..input.length],
        .encoding = input.encoding[0..input.encoding_length],
        .max_bytes = input.limit,
    }) catch {
        result.err = 1;
        return;
    };
    defer decoded.deinit(std.heap.c_allocator);
    @memcpy(input.output[0..decoded.bytes.len], decoded.bytes);
    result.length = decoded.bytes.len;
    result.decoded = @intFromBool(decoded.decoded);
    result.truncated = @intFromBool(decoded.truncated);
    result.failed = @intFromBool(decoded.failed);
}

export fn batch(input: *const Input, iterations: usize) u64 {
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        var result: Result = undefined;
        decode(input, &result);
        checksum += result.length + result.decoded + result.truncated + result.failed + result.err;
    }
    return checksum;
}
