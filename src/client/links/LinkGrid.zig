//! Traverses logical text without mistaking a hard newline for a soft wrap.
const core = @import("telar-core");
const Position = @import("Position.zig");
const LinkGrid = @This();

buffer: *const core.Buffer,
scroll: core.Scroll,
rows: []const core.TextRowFlags = &.{},

pub fn cellIndex(grid: LinkGrid, point: Position) ?usize {
    if (point.x >= grid.buffer.w or point.y < grid.scroll.offset or point.y - grid.scroll.offset >= grid.buffer.h) {
        return null;
    }

    var index = @as(usize, point.y - grid.scroll.offset) * grid.buffer.w + point.x;
    if (grid.padding(index)) {
        return null;
    }

    if (grid.buffer.cells[index].width == 0) {
        if (point.x == 0 or grid.buffer.cells[index - 1].width != 2) {
            return null;
        }

        index -= 1;
    }

    return index;
}

pub fn previous(grid: LinkGrid, index: usize) ?usize {
    var result = index;
    while (result != 0) {
        if (result % grid.buffer.w == 0 and !grid.joins(result / grid.buffer.w - 1)) {
            return null;
        }

        result -= 1;
        if (!grid.padding(result)) {
            return result;
        }
    }

    return null;
}

pub fn next(grid: LinkGrid, index: usize) ?usize {
    var result = index;
    while (result + 1 < grid.buffer.cells.len) {
        if ((result + 1) % grid.buffer.w == 0 and !grid.joins(result / grid.buffer.w)) {
            return null;
        }

        result += 1;
        if (!grid.padding(result)) {
            return result;
        }
    }

    return null;
}

pub fn position(grid: LinkGrid, index: usize) Position {
    return .{ .x = @intCast(index % grid.buffer.w), .y = grid.scroll.offset + @as(u32, @intCast(index / grid.buffer.w)) };
}

pub fn cellEnd(grid: LinkGrid, index: usize) Position {
    var result = grid.position(index);
    result.x = @intCast(@min(grid.buffer.w, @as(u32, result.x) + @max(1, grid.buffer.cells[index].width)));
    return result;
}

fn padding(grid: LinkGrid, index: usize) bool {
    const y = index / grid.buffer.w;
    return y < grid.rows.len and grid.rows[y].wide_padding and index % grid.buffer.w == grid.buffer.w - 1;
}

fn joins(grid: LinkGrid, row: usize) bool {
    return row + 1 < grid.rows.len and grid.rows[row].wrap and grid.rows[row + 1].continuation;
}
