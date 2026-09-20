const std = @import("std");
const Mapping = @import("Mapping.zig");
const Line = @import("telar-core").ChangeReviewDiffLine;
const Self = @This();

allocator: std.mem.Allocator,
origin: usize,
old: bool,
source: std.ArrayList(u8) = .empty,
mappings: std.ArrayList(Mapping) = .empty,

pub fn deinit(self: *Self) void {
    self.source.deinit(self.allocator);
    self.mappings.deinit(self.allocator);
}

pub fn clear(self: *Self) void {
    self.source.clearRetainingCapacity();
    self.mappings.clearRetainingCapacity();
}

/// Reconstructs a diff side without reading the mutable working file.
/// Example: `try before.append(line);`
pub fn append(self: *Self, line: Line) !void {
    try self.mappings.append(self.allocator, .{ .source_start = self.source.items.len, .diff_start = @intFromPtr(line.text.ptr) - self.origin, .len = line.text.len, .apply = !self.old or line.kind == .removed });
    try self.source.appendSlice(self.allocator, line.text);
    try self.source.append(self.allocator, '\n');
}
