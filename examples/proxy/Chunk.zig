/// One read's worth of bytes. Fixed size so the queue is a bounded ring: a
/// runaway producer blocks instead of growing memory.
const Chunk = @This();
const source_namespace = @import("event.zig");
bytes: [4 * source_namespace.KB]u8 = undefined,
len: usize = 0,

pub fn slice(chunk: *const Chunk) []const u8 {
    return chunk.bytes[0..chunk.len];
}
