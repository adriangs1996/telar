//! Damage rows and run diffing shared by the client's composition layers.
//!
//! Three places compare one row of cells against another and copy the runs
//! that differ: pane damage into the composed buffer, the composed buffer
//! into the screen, and chrome regions into the screen. One definition of a
//! damage row and one run walker keep those three from drifting apart - the
//! previous copies disagreed even about what an *empty* row looked like.

const std = @import("std");
const ui = @import("telar-core").ui;

/// One row's dirty range. Empty until marked; `maxInt > 0` makes the default
/// scan `while (x < end)` skip a clean row with no separate flag.
pub const DamageRow = struct {
    start: u16 = std.math.maxInt(u16),
    end: u16 = 0,

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

/// Marks every damage row a linear cell span [start, start+count) touches,
/// splitting the span at row boundaries. The caller validates bounds; this
/// assumes `start + count` lies inside `damage_rows.len * width`.
pub fn markRows(damage_rows: []DamageRow, width: usize, start: usize, count: usize) void {
    if (count == 0) return;
    var cursor = start;
    const end = start + count;
    while (cursor < end) {
        const row = cursor / width;
        const row_end = @min(end, (row + 1) * width);
        damage_rows[row].mark(
            @intCast(cursor % width),
            @intCast(row_end - row * width),
        );
        cursor = row_end;
    }
}

/// Walks [start, end) of one row, finds each run where `source_row` and
/// `reference_row` disagree, and hands it to `sink.copyRun(run_start, count)`.
/// Returns the cells copied. The sink may write into `reference_row`'s
/// memory: every index a run covers has already been compared.
pub fn syncRow(
    source_row: []const ui.Cell,
    reference_row: []const ui.Cell,
    start: u16,
    end: u16,
    sink: anytype,
) !usize {
    var copied: usize = 0;
    var x = start;
    while (x < end) {
        if (source_row[x].eqlPublic(&reference_row[x])) {
            x += 1;
            continue;
        }
        const run_start = x;
        x += 1;
        while (x < end) : (x += 1) {
            if (source_row[x].eqlPublic(&reference_row[x])) break;
        }
        try sink.copyRun(run_start, @intCast(x - run_start));
        copied += x - run_start;
    }
    return copied;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a span crossing rows marks exact damage on each" {
    var rows = [_]DamageRow{.{}} ** 3;
    markRows(&rows, 10, 8, 4);
    try testing.expect(rows[0].dirty());
    try testing.expectEqual(@as(u16, 8), rows[0].start);
    try testing.expectEqual(@as(u16, 10), rows[0].end);
    try testing.expect(rows[1].dirty());
    try testing.expectEqual(@as(u16, 0), rows[1].start);
    try testing.expectEqual(@as(u16, 2), rows[1].end);
    try testing.expect(!rows[2].dirty());
}

test "marks accumulate as one conservative range" {
    var rows = [_]DamageRow{.{}} ** 1;
    markRows(&rows, 10, 1, 1);
    markRows(&rows, 10, 8, 1);
    try testing.expectEqual(@as(u16, 1), rows[0].start);
    try testing.expectEqual(@as(u16, 9), rows[0].end);
    rows[0].clear();
    try testing.expect(!rows[0].dirty());
}

test "run diffing copies exactly the disagreeing runs" {
    var source = [_]ui.Cell{.{}} ** 8;
    var reference = [_]ui.Cell{.{}} ** 8;
    source[1].bytes[0] = 'a';
    source[2].bytes[0] = 'b';
    source[5].bytes[0] = 'c';

    const Sink = struct {
        runs: [4][2]u16 = undefined,
        count: usize = 0,
        pub fn copyRun(sink: *@This(), run_start: u16, count: u16) !void {
            sink.runs[sink.count] = .{ run_start, count };
            sink.count += 1;
        }
    };
    var sink: Sink = .{};
    const copied = try syncRow(&source, &reference, 0, 8, &sink);
    try testing.expectEqual(@as(usize, 3), copied);
    try testing.expectEqual(@as(usize, 2), sink.count);
    try testing.expectEqual([2]u16{ 1, 2 }, sink.runs[0]);
    try testing.expectEqual([2]u16{ 5, 1 }, sink.runs[1]);
}
