const std = @import("std");
const core = @import("telar-core");
/// Bytes every conversation's review files may take on disk together.
pub const max_global_bytes = 256 * 1024 * 1024;
/// Bytes one conversation's manifest and archives may take together.
pub const max_conversation_bytes = 32 * 1024 * 1024;
pub const global_storage_limit = core.Limit.declare("review.global_storage", "bytes", max_global_bytes);
pub const conversation_storage_limit = core.Limit.declare("review.conversation_storage", "bytes", max_conversation_bytes);
io: std.Io,
gpa: std.mem.Allocator,
directory: []const u8,
archive_id: u64 = 0,
byte_limit: u64 = max_conversation_bytes,
global_bytes: ?*usize = null,
global_limit: usize = max_global_bytes,
