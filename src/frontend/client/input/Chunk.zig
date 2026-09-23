const host_inputs = @import("host_inputs.zig");
const Chunk = @This();

bytes: [host_inputs.chunk_size]u8 = undefined,
len: u16 = 0,

pub fn slice(chunk: *const Chunk) []const u8 {
    return chunk.bytes[0..chunk.len];
}
