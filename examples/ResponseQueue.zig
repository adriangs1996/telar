const std = @import("std");
const ResponseQueue = @This();

const capacity = 64;
const max_response_bytes = 1024;

bytes: [capacity][max_response_bytes]u8 = undefined,
lengths: [capacity]u16 = @splat(0),
head: u8 = 0,
len: u8 = 0,
overflowed: bool = false,

pub fn push(queue: *ResponseQueue, response: []const u8) void {
    if (response.len > max_response_bytes or queue.len == capacity) {
        queue.overflowed = true;
        return;
    }
    const index = (@as(usize, queue.head) + queue.len) % capacity;
    @memcpy(queue.bytes[index][0..response.len], response);
    queue.lengths[index] = @intCast(response.len);
    queue.len += 1;
}

pub fn peek(queue: *const ResponseQueue) ?[]const u8 {
    if (queue.len == 0) {
        return null;
    }
    return queue.bytes[queue.head][0..queue.lengths[queue.head]];
}

pub fn pop(queue: *ResponseQueue) void {
    std.debug.assert(queue.len != 0);
    queue.lengths[queue.head] = 0;
    queue.head = @intCast((@as(usize, queue.head) + 1) % capacity);
    queue.len -= 1;
}
