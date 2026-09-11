const PtyResponseQueue = @This();
const source_namespace = @import("root.zig");
const std = @import("std");
mutex: source_namespace.ParkingMutex = .{},
bytes: [source_namespace.max_pty_responses][source_namespace.max_pty_response_bytes]u8 = undefined,
lengths: [source_namespace.max_pty_responses]u16 = @splat(0),
head: u8 = 0,
len: u8 = 0,
dropped: u64 = 0,

pub fn push(queue: *PtyResponseQueue, response: []const u8) bool {
    queue.mutex.lock();
    defer queue.mutex.unlock();
    if (response.len > source_namespace.max_pty_response_bytes or queue.len == source_namespace.max_pty_responses) {
        queue.dropped += 1;
        return false;
    }
    const index = (@as(usize, queue.head) + queue.len) % source_namespace.max_pty_responses;
    @memcpy(queue.bytes[index][0..response.len], response);
    queue.lengths[index] = @intCast(response.len);
    queue.len += 1;
    return true;
}

pub fn peek(queue_const: *const PtyResponseQueue) ?[]const u8 {
    const queue: *PtyResponseQueue = @constCast(queue_const);
    queue.mutex.lock();
    defer queue.mutex.unlock();
    if (queue.len == 0) {
        return null;
    }
    return queue.bytes[queue.head][0..queue.lengths[queue.head]];
}

pub fn pop(queue: *PtyResponseQueue) void {
    queue.mutex.lock();
    defer queue.mutex.unlock();
    std.debug.assert(queue.len != 0);
    queue.lengths[queue.head] = 0;
    queue.head = @intCast((@as(usize, queue.head) + 1) % source_namespace.max_pty_responses);
    queue.len -= 1;
}

pub fn clear(queue: *PtyResponseQueue) void {
    queue.mutex.lock();
    defer queue.mutex.unlock();
    queue.lengths = @splat(0);
    queue.head = 0;
    queue.len = 0;
}
