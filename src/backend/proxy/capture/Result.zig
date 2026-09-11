const std = @import("std");
const Result = @This();

bytes: []u8,
decoded: bool,
truncated: bool,
failed: bool = false,

/// Erases and releases decoded output owned by this result.
///
/// ```zig
/// defer result.deinit(gpa);
/// ```
pub fn deinit(result: *Result, gpa: std.mem.Allocator) void {
    std.crypto.secureZero(u8, result.bytes);
    gpa.free(result.bytes);
    result.* = .{ .bytes = &.{}, .decoded = false, .truncated = false };
}
