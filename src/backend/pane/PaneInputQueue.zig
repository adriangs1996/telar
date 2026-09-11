/// Bytes typed at a child that has not accepted them yet.
///
/// Only the runtime thread mutates this queue; the input-writer actor merely
/// reads the stable chunk it was handed, so no lock is needed. The bound is
/// the explicit backpressure policy: a child that stops draining its PTY for
/// this many bytes is wedged, and dropping its typed-ahead input - counted -
/// mirrors terminal flow control. The alternative, pausing the client socket,
/// froze every other pane's input behind one blocked PTY write.
const PaneInputQueue = @This();
const source_namespace = @import("root.zig");
const std = @import("std");
pub const capacity = 2 * source_namespace.schema.max_input_bytes;

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
pub fn push(queue: *PaneInputQueue, input: []const u8) bool {
    if (input.len > queue.bytes.len - queue.len) {
        queue.dropped_bytes +|= input.len;
        return false;
    }
    var offset: usize = 0;
    while (offset < input.len) {
        const index = (queue.head + queue.len + offset) % queue.bytes.len;
        const run = @min(input.len - offset, queue.bytes.len - index);
        @memcpy(queue.bytes[index..][0..run], input[offset..][0..run]);
        offset += run;
    }
    queue.len += input.len;
    return true;
}

/// The next contiguous run to hand to the PTY writer. Stays valid until
/// `consume`: a wrap-around `push` never writes into `[head, head+len)`.
///
/// ```zig
/// const chunk = queue.nextChunk() orelse return;
/// ```
pub fn nextChunk(queue: *const PaneInputQueue) ?[]const u8 {
    if (queue.len == 0) {
        return null;
    }
    const run = @min(queue.len, queue.bytes.len - queue.head);
    return queue.bytes[queue.head..][0..run];
}

pub fn consume(queue: *PaneInputQueue, count: usize) void {
    std.debug.assert(count <= queue.len);
    queue.head = (queue.head + count) % queue.bytes.len;
    queue.len -= count;
}

pub fn clear(queue: *PaneInputQueue) void {
    queue.head = 0;
    queue.len = 0;
}
