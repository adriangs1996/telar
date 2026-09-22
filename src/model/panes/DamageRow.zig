const std = @import("std");
const DamageRow = @This();

start: u16 = std.math.maxInt(u16),
end: u16 = 0,

/// Accumulates one conservative dirty range. Example: row.mark(2, 5);
pub fn mark(row: *DamageRow, start: u16, end: u16) void {
    std.debug.assert(start < end);
    row.start = @min(row.start, start);
    row.end = @max(row.end, end);
}

pub fn clear(row: *DamageRow) void {
    row.* = .{};
}

pub fn dirty(row: DamageRow) bool {
    return row.start < row.end;
}
