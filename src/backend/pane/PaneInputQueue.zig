const core = @import("telar-core");
const std = @import("std");
/// Bytes typed at a child that has not accepted them yet.
///
/// Only the runtime thread mutates this queue; the input-writer actor merely
/// reads the stable chunk it was handed, so no lock is needed. The bound is
/// the explicit backpressure policy: a child that stops draining its PTY for
/// this many bytes is wedged, and dropping its typed-ahead input - counted -
/// mirrors terminal flow control. The alternative, pausing the client socket,
/// froze every other pane's input behind one blocked PTY write.
const PaneInputQueue = @This();

pub const capacity = 2 * core.max_input_bytes;

bytes: [capacity]u8 = undefined,
head: usize = 0,
len: usize = 0,
dropped_bytes: u64 = 0,

/// All-or-nothing: partial keystroke sequences would corrupt the child's
/// input stream, so a message that does not fit is dropped whole.
///
/// ```zig
/// if (!queue.push(input)) {
///     recordDroppedInput(input.len);
/// }
/// ```
pub fn push(self: *PaneInputQueue, input: []const u8) bool {
    if (input.len > self.bytes.len - self.len) {
        self.dropped_bytes +|= input.len;
        return false;
    }
    var offset: usize = 0;
    while (offset < input.len) {
        const index = (self.head + self.len + offset) % self.bytes.len;
        const run = @min(input.len - offset, self.bytes.len - index);
        @memcpy(self.bytes[index..][0..run], input[offset..][0..run]);
        offset += run;
    }
    self.len += input.len;
    return true;
}

/// The next contiguous run to hand to the PTY writer. Stays valid until
/// `consume`: a wrap-around `push` never writes into `[head, head+len)`.
///
/// ```zig
/// const chunk = queue.nextChunk() orelse return;
/// ```
pub fn nextChunk(self: *const PaneInputQueue) ?[]const u8 {
    if (self.len == 0) {
        return null;
    }
    const run = @min(self.len, self.bytes.len - self.head);
    return self.bytes[self.head..][0..run];
}

pub fn consume(self: *PaneInputQueue, count: usize) void {
    std.debug.assert(count <= self.len);
    self.head = (self.head + count) % self.bytes.len;
    self.len -= count;
}

pub fn clear(self: *PaneInputQueue) void {
    self.head = 0;
    self.len = 0;
}
