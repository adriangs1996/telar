//! Damage rows and run diffing shared by the client's composition layers.
//!
//! Three places compare one row of cells against another and copy the runs
//! that differ: pane damage into the composed buffer, the composed buffer
//! into the screen, and chrome regions into the screen. One definition of a
//! damage row and one run walker keep those three from drifting apart - the
//! previous copies disagreed even about what an *empty* row looked like.

const RowSync = @import("RowSync.zig");
const CellType = @import("telar-core").Cell;
const std = @import("std");

/// Walks [start, end) of one row, finds each run where `source` and
/// `reference` disagree, and hands it to `sink.copyRun(run_start, count)`.
/// Returns the cells copied. The sink may write into `reference`'s
/// memory: every index a run covers has already been compared.
/// For example: `const copied = try syncRow(.{ .source = source, .reference = reference, .start = 0, .end = width }, sink);`.
pub fn syncRow(sync: RowSync, sink: anytype) !usize {
    var copied: usize = 0;
    var x = sync.start;
    while (x < sync.end) {
        if (sync.source[x].eqlPublic(&sync.reference[x])) {
            x += 1;
            continue;
        }
        const run_start = x;
        x += 1;
        while (x < sync.end) : (x += 1) {
            if (sync.source[x].eqlPublic(&sync.reference[x])) {
                break;
            }
        }
        try sink.copyRun(run_start, @intCast(x - run_start));
        copied += x - run_start;
    }
    return copied;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "run diffing copies exactly the disagreeing runs" {
    var source = [_]CellType{.{}} ** 8;
    var reference = [_]CellType{.{}} ** 8;
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
    const copied = try syncRow(.{ .source = &source, .reference = &reference, .start = 0, .end = 8 }, &sink);
    try std.testing.expectEqual(@as(usize, 3), copied);
    try std.testing.expectEqual(@as(usize, 2), sink.count);
    try std.testing.expectEqual([2]u16{ 1, 2 }, sink.runs[0]);
    try std.testing.expectEqual([2]u16{ 5, 1 }, sink.runs[1]);
}
