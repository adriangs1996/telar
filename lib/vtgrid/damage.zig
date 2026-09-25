//! Cost-aware frame spans from conservative terminal row damage.

const cellcodec = @import("cellcodec");
const cellgrid = @import("cellgrid");
const Diff = @import("Diff.zig");
const Counting = @import("Counting.zig").Counting;
const std = @import("std");

/// Compares only rows which RenderState reported as dirty.
///
/// A dirty row is conservative. It may finish equal to the acknowledged
/// screen after several PTY writes cancel each other out. Runs on the same row
/// share a span when encoding their unchanged gap costs no more than another
/// span header. Adjacent runs across a row boundary also remain one span.
/// `Diff.comparisons` is filled only when `counting` is `.comparisons`.
///
/// ```zig
/// const diff = collectSpans(Span, .off, .{ .current = current, .acknowledged = acknowledged, .cols = cols, .damaged_rows = damaged, .span_header_size = 12 }, storage);
/// ```
pub fn collectSpans(comptime Span: type, comptime counting: Counting, input: Input, storage: []Span) Diff {
    const current = input.current;
    const acknowledged = input.acknowledged;
    const cols = input.cols;
    const damaged_rows = input.damaged_rows;

    std.debug.assert(cols != 0);
    std.debug.assert(current.len == acknowledged.len);
    std.debug.assert(current.len == @as(usize, cols) * damaged_rows.len);

    var result: Diff = .{};
    const span_header_size = input.span_header_size;
    for (damaged_rows, 0..) |damaged, y| {
        if (!damaged) {
            continue;
        }
        result.damaged_rows += 1;
        result.scanned_cells += cols;

        var index = y * @as(usize, cols);
        const row_end = index + cols;
        while (index < row_end) {
            if (compare: {
                if (counting == .comparisons) {
                    result.comparisons += 1;
                }

                break :compare current[index].eqlPublic(&acknowledged[index]);
            }) {
                index += 1;
                continue;
            }

            const start = index;
            while (index < row_end and
                compare: {
                    if (counting == .comparisons) {
                        result.comparisons += 1;
                    }

                    break :compare !current[index].eqlPublic(&acknowledged[index]);
                })
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
                const maximum_profitable_gap = span_header_size +
                    cellcodec.max_style_size;
                if (previous_end / cols == start / cols and
                    gap_len <= maximum_profitable_gap)
                {
                    const previous_style = previous.cells[previous.cells.len - 1].style;
                    const gap = current[previous_end..start];
                    const merged_cost = cellcodec.encodedCellsSize(gap, previous_style) +
                        cellcodec.encodedCellSize(current[start], gap[gap.len - 1].style);
                    const separate_cost = span_header_size +
                        cellcodec.encodedCellSize(current[start], null);
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

/// A positioned run of cells, the shape `collectSpans` fills.
const TestSpan = struct {
    start: u32,
    cells: []const cellgrid.Cell,
};

/// The frame protocol's span header: start, count and encoded length.
const test_span_header_size = 12;

test "damage limits patch generation to dirty rows" {
    const acknowledged = [_]cellgrid.Cell{.{}} ** 12;
    var current = acknowledged;
    current[1].bytes[0] = 'x';
    current[9].bytes[0] = 'y';
    const damaged_rows = [_]bool{ true, false, false };
    var spans: [4]TestSpan = undefined;

    const diff = collectSpans(TestSpan, .off, .{ .current = &current, .acknowledged = &acknowledged, .cols = 4, .damaged_rows = &damaged_rows, .span_header_size = test_span_header_size }, &spans);
    try std.testing.expectEqual(@as(usize, 1), diff.damaged_rows);
    try std.testing.expectEqual(@as(usize, 4), diff.scanned_cells);
    try std.testing.expectEqual(@as(usize, 1), diff.span_count);
    try std.testing.expectEqual(@as(u32, 1), spans[0].start);
    try std.testing.expectEqual(@as(usize, 1), spans[0].cells.len);
}

test "damage from separate rows accumulates without scanning the gap" {
    const acknowledged = [_]cellgrid.Cell{.{}} ** 12;
    var current = acknowledged;
    current[1].bytes[0] = 'x';
    current[9].bytes[0] = 'y';
    const damaged_rows = [_]bool{ true, false, true };
    var spans: [4]TestSpan = undefined;

    const diff = collectSpans(TestSpan, .off, .{ .current = &current, .acknowledged = &acknowledged, .cols = 4, .damaged_rows = &damaged_rows, .span_header_size = test_span_header_size }, &spans);
    try std.testing.expectEqual(@as(usize, 2), diff.damaged_rows);
    try std.testing.expectEqual(@as(usize, 8), diff.scanned_cells);
    try std.testing.expectEqual(@as(usize, 2), diff.span_count);
    try std.testing.expectEqual(@as(u32, 1), spans[0].start);
    try std.testing.expectEqual(@as(u32, 9), spans[1].start);
}

test "adjacent damage across rows stays one span" {
    const acknowledged = [_]cellgrid.Cell{.{}} ** 8;
    var current = acknowledged;
    current[3].bytes[0] = 'x';
    current[4].bytes[0] = 'y';
    const damaged_rows = [_]bool{ true, true };
    var spans: [2]TestSpan = undefined;

    const diff = collectSpans(TestSpan, .off, .{ .current = &current, .acknowledged = &acknowledged, .cols = 4, .damaged_rows = &damaged_rows, .span_header_size = test_span_header_size }, &spans);
    try std.testing.expectEqual(@as(usize, 1), diff.span_count);
    try std.testing.expectEqual(@as(u32, 3), spans[0].start);
    try std.testing.expectEqual(@as(usize, 2), spans[0].cells.len);
}

test "short unchanged gaps share a cheaper span" {
    const acknowledged = [_]cellgrid.Cell{.{}} ** 8;
    var current = acknowledged;
    current[1].bytes[0] = 'x';
    current[4].bytes[0] = 'y';
    const damaged_rows = [_]bool{true};
    var spans: [2]TestSpan = undefined;

    const diff = collectSpans(TestSpan, .off, .{ .current = &current, .acknowledged = &acknowledged, .cols = 8, .damaged_rows = &damaged_rows, .span_header_size = test_span_header_size }, &spans);
    try std.testing.expectEqual(@as(usize, 1), diff.span_count);
    try std.testing.expectEqual(@as(usize, 1), diff.coalesced_spans);
    try std.testing.expectEqual(@as(usize, 2), diff.bridged_cells);
    try std.testing.expectEqual(@as(u32, 1), spans[0].start);
    try std.testing.expectEqual(@as(usize, 4), spans[0].cells.len);

    const separate_size = 2 * test_span_header_size +
        cellcodec.encodedCellsSize(current[1..2], null) +
        cellcodec.encodedCellsSize(current[4..5], null);
    const merged_size = test_span_header_size +
        cellcodec.encodedCellsSize(current[1..5], null);
    try std.testing.expectEqual(separate_size - merged_size, diff.bytes_saved);
}

test "an expensive gap keeps separate spans" {
    const acknowledged = [_]cellgrid.Cell{.{}} ** 32;
    var current = acknowledged;
    current[1].bytes[0] = 'x';
    current[30].bytes[0] = 'y';
    const damaged_rows = [_]bool{true};
    var spans: [2]TestSpan = undefined;

    const diff = collectSpans(TestSpan, .off, .{ .current = &current, .acknowledged = &acknowledged, .cols = 32, .damaged_rows = &damaged_rows, .span_header_size = test_span_header_size }, &spans);
    try std.testing.expectEqual(@as(usize, 2), diff.span_count);
    try std.testing.expectEqual(@as(usize, 0), diff.coalesced_spans);
    try std.testing.expectEqual(@as(usize, 0), diff.bridged_cells);
}

test "too many damaged runs request a snapshot" {
    const acknowledged = [_]cellgrid.Cell{.{}} ** 32;
    var current = acknowledged;
    current[0].bytes[0] = 'x';
    current[31].bytes[0] = 'y';
    const damaged_rows = [_]bool{true};
    var spans: [1]TestSpan = undefined;

    const diff = collectSpans(TestSpan, .off, .{ .current = &current, .acknowledged = &acknowledged, .cols = 32, .damaged_rows = &damaged_rows, .span_header_size = test_span_header_size }, &spans);
    try std.testing.expect(diff.snapshot_required);
}

test "counting comparisons leaves every span and statistic unchanged" {
    const cols = 16;
    const rows = 6;
    var prng = std.Random.DefaultPrng.init(0x7e1a);
    const random = prng.random();

    for (0..200) |_| {
        var acknowledged: [cols * rows]cellgrid.Cell = @splat(.{});
        var current = acknowledged;
        var damaged_rows: [rows]bool = undefined;
        for (&damaged_rows) |*damaged| {
            damaged.* = random.boolean();
        }

        for (&current) |*cell| {
            if (random.uintLessThan(u8, 4) == 0) {
                cell.bytes[0] = 'a' + random.uintLessThan(u8, 3);
            }
        }

        var counted_spans: [8]TestSpan = undefined;
        var plain_spans: [8]TestSpan = undefined;
        const input: Input = .{
            .current = &current,
            .acknowledged = &acknowledged,
            .cols = cols,
            .damaged_rows = &damaged_rows,
            .span_header_size = test_span_header_size,
        };
        const counted = collectSpans(TestSpan, .comparisons, input, &counted_spans);
        const plain = collectSpans(TestSpan, .off, input, &plain_spans);

        var expected = counted;
        expected.comparisons = 0;
        try std.testing.expectEqualDeep(expected, plain);
        try std.testing.expectEqualDeep(counted_spans[0..counted.span_count], plain_spans[0..plain.span_count]);
        if (!counted.snapshot_required) {
            try std.testing.expect(counted.comparisons >= counted.scanned_cells);
        }
    }
}

const Input = struct {
    current: []const cellgrid.Cell,
    acknowledged: []const cellgrid.Cell,
    cols: u16,
    damaged_rows: []const bool,
    /// Bytes the caller's encoding spends to start another span; a gap
    /// cheaper to encode than this joins the spans around it.
    span_header_size: usize,
};
