const event = @import("event.zig");
/// One read's worth of bytes. Fixed size so the queue is a bounded ring: a
/// runaway producer blocks instead of growing memory.
const Chunk = @This();

bytes: [4 * event.KB]u8 = undefined,
len: usize = 0,

pub fn slice(chunk: *const Chunk) []const u8 {
    return chunk.bytes[0..chunk.len];
}
