//! One directory name inside the listed base directory.
const PathCompletionResult = @import("PathCompletionResult.zig");
const Entry = @This();

name: [PathCompletionResult.max_name_bytes]u8 = undefined,
len: u8 = 0,

pub fn slice(self: *const Entry) []const u8 {
    return self.name[0..self.len];
}
