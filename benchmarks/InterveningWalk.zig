//! Unrelated memory read between idle flushes, with every flush timed on its
//! own. The walk changes what a flush finds in the processor's caches by an
//! amount nothing here measures: its size names no cache level and proves no
//! eviction. The two sums stay apart so a reader can see how much of a timed
//! flush is the clock itself.
const std = @import("std");
const InterveningWalk = @This();

/// Bytes between two reads of one walk.
pub const stride_bytes = 64;
/// Largest walk accepted, so a mistyped size cannot ask for the host's memory.
pub const max_bytes = 1024 * 1024 * 1024;

memory: []u8,
/// Flushes timed so far, the benchmark's calibration and warmup included.
flushes: u64 = 0,
/// Sum of the clock intervals that each enclose one flush.
flush_ns: u64 = 0,
/// Sum of as many clock intervals that enclose nothing, taken after a walk.
empty_clock_ns: u64 = 0,

/// Maps and touches `bytes` of memory no fixture uses.
///
/// ```zig
/// var walk = try InterveningWalk.init(512 * 1024);
/// defer walk.deinit();
/// ```
pub fn init(bytes: usize) !InterveningWalk {
    const memory = try std.heap.page_allocator.alloc(u8, bytes);
    @memset(memory, 1);
    return .{
        .memory = memory,
    };
}

/// Example: `walk.deinit();`.
pub fn deinit(self: *InterveningWalk) void {
    std.heap.page_allocator.free(self.memory);
}

/// Writes both sums as they are, in nanoseconds over `flushes` flushes;
/// subtracting one from the other is left to the reader.
///
/// ```zig
/// try walk.write(writer, case.name);
/// ```
pub fn write(self: *const InterveningWalk, writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print(
        "{{\"type\":\"intervening_walk\",\"name\":\"{s}\",\"walk_bytes\":{d},\"walk_stride_bytes\":{d}," ++
            "\"flushes\":{d},\"flush_ns\":{d},\"empty_clock_ns\":{d}}}\n",
        .{
            name,
            self.memory.len,
            stride_bytes,
            self.flushes,
            self.flush_ns,
            self.empty_clock_ns,
        },
    );
}

/// Reads one byte every `stride_bytes` across the whole walk.
///
/// ```zig
/// checksum +%= walk.read();
/// ```
pub noinline fn read(self: *const InterveningWalk) u64 {
    // Hiding the slice keeps the compiler from proving that two walks read
    // the same bytes and folding the second into the first.
    var memory = self.memory;
    std.mem.doNotOptimizeAway(&memory);

    var sum: u64 = 0;
    var index: usize = 0;
    while (index < memory.len) : (index += stride_bytes) {
        sum +%= memory[index];
    }

    return sum;
}
