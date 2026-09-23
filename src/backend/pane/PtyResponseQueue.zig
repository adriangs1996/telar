const ParkingMutex = @import("../media/ParkingMutex.zig");
const pane_namespace = @import("pane_namespace.zig");
const std = @import("std");
const PtyResponseQueue = @This();

mutex: ParkingMutex = .{},
bytes: [pane_namespace.max_pty_responses][pane_namespace.max_pty_response_bytes]u8 = undefined,
lengths: [pane_namespace.max_pty_responses]u16 = @splat(0),
head: u8 = 0,
len: u8 = 0,
dropped: u64 = 0,

pub fn push(self: *PtyResponseQueue, response: []const u8) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (response.len > pane_namespace.max_pty_response_bytes or self.len == pane_namespace.max_pty_responses) {
        self.dropped += 1;
        return false;
    }
    const index = (@as(usize, self.head) + self.len) % pane_namespace.max_pty_responses;
    @memcpy(self.bytes[index][0..response.len], response);
    self.lengths[index] = @intCast(response.len);
    self.len += 1;
    return true;
}

pub fn peek(self: *const PtyResponseQueue) ?[]const u8 {
    const queue: *PtyResponseQueue = @constCast(self);
    queue.mutex.lock();
    defer queue.mutex.unlock();
    if (queue.len == 0) {
        return null;
    }
    return queue.bytes[queue.head][0..queue.lengths[queue.head]];
}

pub fn pop(self: *PtyResponseQueue) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    std.debug.assert(self.len != 0);
    self.lengths[self.head] = 0;
    self.head = @intCast((@as(usize, self.head) + 1) % pane_namespace.max_pty_responses);
    self.len -= 1;
}

pub fn clear(self: *PtyResponseQueue) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.lengths = @splat(0);
    self.head = 0;
    self.len = 0;
}
