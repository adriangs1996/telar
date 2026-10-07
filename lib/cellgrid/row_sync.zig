//! Run diffing between two rows of cells: one walker for every layer that
//! copies only the cells that changed, so they agree even about what an
//! empty row looks like.
const Cell = @import("Cell.zig");

/// Walks [start, end) of one row, finds each run where `source` and
/// `reference` disagree, and hands it to `sink.copyRun(run_start, count)`.
/// Returns the cells copied. The sink may write into `reference`'s
/// memory: every index a run covers has already been compared.
/// For example: `const copied = try cellgrid.syncRow(.{ .source = source, .reference = reference, .start = 0, .end = width }, sink);`.
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

const RowSync = struct {
    source: []const Cell,
    reference: []const Cell,
    start: u16,
    end: u16,
};
