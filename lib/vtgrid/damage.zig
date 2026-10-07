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

const Input = struct {
    current: []const cellgrid.Cell,
    acknowledged: []const cellgrid.Cell,
    cols: u16,
    damaged_rows: []const bool,
    /// Bytes the caller's encoding spends to start another span; a gap
    /// cheaper to encode than this joins the spans around it.
    span_header_size: usize,
};
