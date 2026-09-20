//! Borrowed source line and its coordinates in the old and new files.
pub const Kind = enum { file, hunk, context, added, removed, metadata };

kind: Kind,
text: []const u8,
old: ?u32 = null,
new: ?u32 = null,
operation: []const u8 = "",
