const std = @import("std");
/// In-progress deflate of one image's pixels. Heap-allocated and never moved,
/// because the compressor holds pointers into the allocating writer and the
/// window buffer.
const Compression = @This();

input: []u8 = &.{},
input_len: usize = 0,
finish_after: bool = false,
failed: bool = false,
allocating: std.Io.Writer.Allocating,
window: [std.compress.flate.max_window_len]u8,
compress: std.compress.flate.Compress,
offset: usize,

/// Compresses only copied input; no store, image or mutable model is borrowed.
/// Example: `const completed = Compression.run(job);`.
pub fn run(job: *Compression) *Compression {
    job.compress.writer.writeAll(job.input[0..job.input_len]) catch {
        job.failed = true;
        return job;
    };
    if (job.finish_after) {
        job.compress.finish() catch {
            job.failed = true;
        };
    }

    return job;
}
