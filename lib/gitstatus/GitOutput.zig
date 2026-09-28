const std = @import("std");
/// What a Git child printed; free it with `deinit`.
const GitOutput = @This();

stdout: []u8,

pub fn deinit(self: GitOutput) void {
    std.heap.page_allocator.free(self.stdout);
}

/// The output without surrounding blank space.
/// Example: `const merge_base = output.line();`.
pub fn line(self: GitOutput) []const u8 {
    return std.mem.trim(u8, self.stdout, " \r\n");
}
