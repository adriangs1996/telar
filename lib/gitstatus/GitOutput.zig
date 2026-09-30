const std = @import("std");
/// What a Git child printed; free it with `deinit`.
const GitOutput = @This();

stdout: []u8,
/// Bytes printed before `stdout` that a tail bound dropped.
dropped: u64 = 0,

pub fn deinit(self: GitOutput) void {
    std.heap.page_allocator.free(self.stdout);
}

/// The output without surrounding blank space.
/// Example: `const merge_base = output.line();`.
pub fn line(self: GitOutput) []const u8 {
    return std.mem.trim(u8, self.stdout, " \r\n");
}

/// Whether Git printed anything, kept or dropped.
/// Example: `const dirty = output.printed();`.
pub fn printed(self: GitOutput) bool {
    return self.stdout.len != 0 or self.dropped != 0;
}
