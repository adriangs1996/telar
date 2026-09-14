//! One directory name inside the listed base directory.
const max_name_bytes_module = @import("PathCompletionResult.zig").max_name_bytes;
const Entry = @This();

name: [max_name_bytes_module]u8 = undefined,
len: u8 = 0,

pub fn slice(entry: *const Entry) []const u8 {
    return entry.name[0..entry.len];
}
