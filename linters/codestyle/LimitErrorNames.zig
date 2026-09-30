//! The error names `src/core/limit_reached.zig` declares in its sets, where
//! each is declared, and which of them the checked files raise. Names
//! borrow that file's source.
const std = @import("std");
const LimitErrorNames = @This();

/// Where a member is declared and whether it is a `LimitError` member,
/// which some file must raise.
const Member = struct {
    start: usize,
    limit: bool,
    raised: bool = false,
};

members: std.StringHashMapUnmanaged(Member) = .empty,

pub fn deinit(self: *LimitErrorNames, allocator: std.mem.Allocator) void {
    self.members.deinit(allocator);
}

/// Example: `if (!names.contains("TooManyTabs")) ...`
pub fn contains(self: *const LimitErrorNames, name: []const u8) bool {
    return self.members.contains(name);
}
