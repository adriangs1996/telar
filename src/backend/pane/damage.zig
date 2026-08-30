//! Cost-aware frame spans from conservative terminal row damage.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const Diff = struct {
    span_count: usize = 0,
    damaged_rows: usize = 0,
    scanned_cells: usize = 0,
    coalesced_spans: usize = 0,
    bridged_cells: usize = 0,
    bytes_saved: usize = 0,
    snapshot_required: bool = false,
};

pub const Input = struct {
    current: []const core.ui.Cell,
    acknowledged: []const core.ui.Cell,
    cols: u16,
    damaged_rows: []const bool,
};

/// Compares only rows which RenderState reported as dirty.
///
/// A dirty row is conservative. It may finish equal to the acknowledged
/// screen after several PTY writes cancel each other out. Runs on the same row
/// share a span when encoding their unchanged gap costs no more than another
/// span header. Adjacent runs across a row boundary also remain one span.
///
/// ```zig
/// const diff = collectSpans(.{ .current = current, .acknowledged = acknowledged, .cols = cols, .damaged_rows = damaged }, storage);
/// ```
pub fn collectSpans(input: Input, storage: []schema.frame.Span) Diff {
    const current = input.current;
    const acknowledged = input.acknowledged;
    const cols = input.cols;
    const damaged_rows = input.damaged_rows;

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
                const previous_end = previous_start + previous.cells.len;
                if (previous_end == start) {
                    previous.cells = current[previous_start..index];
                    continue;
                }
                const gap_len = start - previous_end;
                const maximum_profitable_gap = schema.frame.span_header_size +
                    schema.frame.max_style_size;
                if (previous_end / cols == start / cols and
                    gap_len <= maximum_profitable_gap)
                {
                    const previous_style = previous.cells[previous.cells.len - 1].style;
                    const gap = current[previous_end..start];
                    const merged_cost = schema.frame.encodedCellsSize(gap, previous_style) +
                        schema.frame.encodedCellSize(current[start], gap[gap.len - 1].style);
                    const separate_cost = schema.frame.span_header_size +
                        schema.frame.encodedCellSize(current[start], null);
                    if (merged_cost <= separate_cost) {
                        previous.cells = current[previous_start..index];
                        result.coalesced_spans += 1;
                        result.bridged_cells += gap_len;
                        result.bytes_saved += separate_cost - merged_cost;
                        continue;
                    }
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

    const diff = collectSpans(.{ .current = &current, .acknowledged = &acknowledged, .cols = 4, .damaged_rows = &damaged_rows }, &spans);
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

    const diff = collectSpans(.{ .current = &current, .acknowledged = &acknowledged, .cols = 4, .damaged_rows = &damaged_rows }, &spans);
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

    const diff = collectSpans(.{ .current = &current, .acknowledged = &acknowledged, .cols = 4, .damaged_rows = &damaged_rows }, &spans);
    try std.testing.expectEqual(@as(usize, 1), diff.span_count);
    try std.testing.expectEqual(@as(u32, 3), spans[0].start);
    try std.testing.expectEqual(@as(usize, 2), spans[0].cells.len);
}

test "short unchanged gaps share a cheaper span" {
    const acknowledged = [_]core.ui.Cell{.{}} ** 8;
    var current = acknowledged;
    current[1].bytes[0] = 'x';
    current[4].bytes[0] = 'y';
    const damaged_rows = [_]bool{true};
    var spans: [2]schema.frame.Span = undefined;

    const diff = collectSpans(.{ .current = &current, .acknowledged = &acknowledged, .cols = 8, .damaged_rows = &damaged_rows }, &spans);
    try std.testing.expectEqual(@as(usize, 1), diff.span_count);
    try std.testing.expectEqual(@as(usize, 1), diff.coalesced_spans);
    try std.testing.expectEqual(@as(usize, 2), diff.bridged_cells);
    try std.testing.expectEqual(@as(u32, 1), spans[0].start);
    try std.testing.expectEqual(@as(usize, 4), spans[0].cells.len);

    const separate_size = 2 * schema.frame.span_header_size +
        schema.frame.encodedCellsSize(current[1..2], null) +
        schema.frame.encodedCellsSize(current[4..5], null);
    const merged_size = schema.frame.span_header_size +
        schema.frame.encodedCellsSize(current[1..5], null);
    try std.testing.expectEqual(separate_size - merged_size, diff.bytes_saved);
}

test "an expensive gap keeps separate spans" {
    const acknowledged = [_]core.ui.Cell{.{}} ** 32;
    var current = acknowledged;
    current[1].bytes[0] = 'x';
    current[30].bytes[0] = 'y';
    const damaged_rows = [_]bool{true};
    var spans: [2]schema.frame.Span = undefined;

    const diff = collectSpans(.{ .current = &current, .acknowledged = &acknowledged, .cols = 32, .damaged_rows = &damaged_rows }, &spans);
    try std.testing.expectEqual(@as(usize, 2), diff.span_count);
    try std.testing.expectEqual(@as(usize, 0), diff.coalesced_spans);
    try std.testing.expectEqual(@as(usize, 0), diff.bridged_cells);
}

test "too many damaged runs request a snapshot" {
    const acknowledged = [_]core.ui.Cell{.{}} ** 32;
    var current = acknowledged;
    current[0].bytes[0] = 'x';
    current[31].bytes[0] = 'y';
    const damaged_rows = [_]bool{true};
    var spans: [1]schema.frame.Span = undefined;

    const diff = collectSpans(.{ .current = &current, .acknowledged = &acknowledged, .cols = 32, .damaged_rows = &damaged_rows }, &spans);
    try std.testing.expect(diff.snapshot_required);
}
