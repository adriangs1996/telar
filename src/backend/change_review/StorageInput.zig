const std = @import("std");
pub const max_global_bytes = 256 * 1024 * 1024;
io: std.Io,
gpa: std.mem.Allocator,
directory: []const u8,
archive_id: u64 = 0,
byte_limit: u64 = 8 * 1024 * 1024,
global_bytes: ?*usize = null,
global_limit: usize = max_global_bytes,
