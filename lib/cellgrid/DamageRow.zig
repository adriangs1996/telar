const std = @import("std");
const DamageRow = @This();

start: u16 = std.math.maxInt(u16),
end: u16 = 0,

/// Accumulates one conservative dirty range. Example: row.mark(2, 5);
pub fn mark(self: *DamageRow, start: u16, end: u16) void {
    std.debug.assert(start < end);
    self.start = @min(self.start, start);
    self.end = @max(self.end, end);
}

pub fn clear(self: *DamageRow) void {
    self.* = .{};
}

pub fn dirty(self: DamageRow) bool {
    return self.start < self.end;
}
