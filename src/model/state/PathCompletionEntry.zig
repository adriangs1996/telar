//! One directory name inside the listed base directory.
const PathCompletionResult = @import("PathCompletionResult.zig");
const Entry = @This();

// SAFETY: PathCompletionResult copies each name before storing the entry; slice exposes only len bytes.
name: [PathCompletionResult.max_name_bytes]u8 = undefined,
len: u8 = 0,

pub fn slice(self: *const Entry) []const u8 {
    return self.name[0..self.len];
}
