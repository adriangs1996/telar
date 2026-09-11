/// Bytes borrowed by the write worker until the owning state receives completion.
const WriteJob = @This();
const source_namespace = @import("session_checkpoint.zig");
io: source_namespace.Io,
path: []const u8,
buffer: []u8,
len: usize,

pub fn bytes(job: *const WriteJob) []const u8 {
    return job.buffer[0..job.len];
}
