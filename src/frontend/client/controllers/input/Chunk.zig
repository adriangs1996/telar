const Chunk = @This();
const source_namespace = @import("host_inputs.zig");
bytes: [source_namespace.chunk_size]u8 = undefined,
len: u16 = 0,

pub fn slice(chunk: *const Chunk) []const u8 {
    return chunk.bytes[0..chunk.len];
}
