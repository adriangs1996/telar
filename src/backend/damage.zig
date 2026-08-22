//! Exact frame spans from conservative terminal row damage.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema.v2;

pub const Diff = struct {
    span_count: usize = 0,
    damaged_rows: usize = 0,
    scanned_cells: usize = 0,
    snapshot_required: bool = false,
};

/// Compares only rows which RenderState reported as dirty.
///
/// A dirty row is conservative. It may finish equal to the acknowledged
/// screen after several PTY writes cancel each other out. Exact spans still
/// come from comparing cells inside those rows. Adjacent runs across a row
/// boundary remain one span.
pub fn collectSpans(
    current: []const core.ui.Cell,
    acknowledged: []const core.ui.Cell,
    cols: u16,
    damaged_rows: []const bool,
    storage: []schema.frame.Span,
) Diff {
    std.debug.assert(cols != 0);
    std.debug.assert(current.len == acknowledged.len);
    std.debug.assert(current.len == @as(usize, cols) * damaged_rows.len);

    var result: Diff = .{};
    for (damaged_rows, 0..) |damaged, y| {
        if (!damaged) continue;
        result.damaged_rows += 1;
        result.scanned_cells += cols;

        var index = y * @as(usize, cols);
        const row_end = index + cols;
        while (index < row_end) {
            if (current[index].eqlPublic(&acknowledged[index])) {
                index += 1;
                continue;
            }

            const start = index;
            while (index < row_end and
                !current[index].eqlPublic(&acknowledged[index]))
            {
                index += 1;
            }

            if (result.span_count != 0) {
                const previous = &storage[result.span_count - 1];
                const previous_start: usize = @intCast(previous.start);
                if (previous_start + previous.cells.len == start) {
                    previous.cells = current[previous_start..index];
                    continue;
                }
            }
            if (result.span_count == storage.len) {
                result.snapshot_required = true;
                return result;
            }
            storage[result.span_count] = .{
                .start = @intCast(start),
                .cells = current[start..index],
            };
            result.span_count += 1;
        }
    }
    return result;
}

test "damage limits patch generation to dirty rows" {
    const acknowledged = [_]core.ui.Cell{.{}} ** 12;
    var current = acknowledged;
    current[1].bytes[0] = 'x';
    current[9].bytes[0] = 'y';
    const damaged_rows = [_]bool{ true, false, false };
    var spans: [4]schema.frame.Span = undefined;

    const diff = collectSpans(&current, &acknowledged, 4, &damaged_rows, &spans);
    try std.testing.expectEqual(@as(usize, 1), diff.damaged_rows);
    try std.testing.expectEqual(@as(usize, 4), diff.scanned_cells);
    try std.testing.expectEqual(@as(usize, 1), diff.span_count);
    try std.testing.expectEqual(@as(u32, 1), spans[0].start);
    try std.testing.expectEqual(@as(usize, 1), spans[0].cells.len);
}

test "damage from separate rows accumulates without scanning the gap" {
    const acknowledged = [_]core.ui.Cell{.{}} ** 12;
    var current = acknowledged;
    current[1].bytes[0] = 'x';
    current[9].bytes[0] = 'y';
    const damaged_rows = [_]bool{ true, false, true };
    var spans: [4]schema.frame.Span = undefined;

    const diff = collectSpans(&current, &acknowledged, 4, &damaged_rows, &spans);
    try std.testing.expectEqual(@as(usize, 2), diff.damaged_rows);
    try std.testing.expectEqual(@as(usize, 8), diff.scanned_cells);
    try std.testing.expectEqual(@as(usize, 2), diff.span_count);
    try std.testing.expectEqual(@as(u32, 1), spans[0].start);
    try std.testing.expectEqual(@as(u32, 9), spans[1].start);
}

test "adjacent damage across rows stays one span" {
    const acknowledged = [_]core.ui.Cell{.{}} ** 8;
    var current = acknowledged;
    current[3].bytes[0] = 'x';
    current[4].bytes[0] = 'y';
    const damaged_rows = [_]bool{ true, true };
    var spans: [2]schema.frame.Span = undefined;

    const diff = collectSpans(&current, &acknowledged, 4, &damaged_rows, &spans);
    try std.testing.expectEqual(@as(usize, 1), diff.span_count);
    try std.testing.expectEqual(@as(u32, 3), spans[0].start);
    try std.testing.expectEqual(@as(usize, 2), spans[0].cells.len);
}

test "too many damaged runs request a snapshot" {
    const acknowledged = [_]core.ui.Cell{.{}} ** 4;
    var current = acknowledged;
    current[0].bytes[0] = 'x';
    current[2].bytes[0] = 'y';
    const damaged_rows = [_]bool{true};
    var spans: [1]schema.frame.Span = undefined;

    const diff = collectSpans(&current, &acknowledged, 4, &damaged_rows, &spans);
    try std.testing.expect(diff.snapshot_required);
}
