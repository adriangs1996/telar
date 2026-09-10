//! Bounded cell damage independent of the eventual presentation target.

const std = @import("std");

pub const DamageRow = struct {
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
};

pub const CellSpan = struct {
    start: usize,
    count: usize,
};

/// Splits a validated cell span at row boundaries without allocating.
/// The caller guarantees start + count <= rows.len * width.
/// Example: markRows(rows, width, .{ .start = 8, .count = 4 });
pub fn markRows(rows: []DamageRow, width: usize, span: CellSpan) void {
    if (span.count == 0) {
        return;
    }

    var cursor = span.start;
    const end = span.start + span.count;
    while (cursor < end) {
        const row = cursor / width;
        const row_end = @min(end, (row + 1) * width);
        rows[row].mark(@intCast(cursor % width), @intCast(row_end - row * width));
        cursor = row_end;
    }
}

test "a span crossing rows marks exact damage on each" {
    var rows = [_]DamageRow{.{}} ** 3;
    markRows(&rows, 10, .{ .start = 8, .count = 4 });
    try std.testing.expect(rows[0].dirty());
    try std.testing.expectEqual(@as(u16, 8), rows[0].start);
    try std.testing.expectEqual(@as(u16, 10), rows[0].end);
    try std.testing.expectEqual(@as(u16, 0), rows[1].start);
    try std.testing.expectEqual(@as(u16, 2), rows[1].end);
    try std.testing.expect(!rows[2].dirty());
}

test "marks accumulate as one conservative range" {
    var rows = [_]DamageRow{.{}} ** 1;
    markRows(&rows, 10, .{ .start = 1, .count = 1 });
    markRows(&rows, 10, .{ .start = 8, .count = 1 });
    try std.testing.expectEqual(@as(u16, 1), rows[0].start);
    try std.testing.expectEqual(@as(u16, 9), rows[0].end);
    rows[0].clear();
    try std.testing.expect(!rows[0].dirty());
}
