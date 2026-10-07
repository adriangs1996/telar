//! Bounded cell damage independent of the eventual presentation target.

const DamageRow = @import("DamageRow.zig");
const CellSpan = @import("CellSpan.zig");

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
