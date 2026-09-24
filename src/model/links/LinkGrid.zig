//! Traverses logical text without mistaking a hard newline for a soft wrap.
const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const Position = @import("Position.zig");
const LinkGrid = @This();

buffer: *const cellgrid.Buffer,
scroll: core.Scroll,
rows: []const core.TextRowFlags = &.{},

pub fn cellIndex(self: LinkGrid, point: Position) ?usize {
    if (point.x >= self.buffer.w or point.y < self.scroll.offset or point.y - self.scroll.offset >= self.buffer.h) {
        return null;
    }

    var index = @as(usize, point.y - self.scroll.offset) * self.buffer.w + point.x;
    if (self.padding(index)) {
        return null;
    }

    if (self.buffer.cells[index].width == 0) {
        if (point.x == 0 or self.buffer.cells[index - 1].width != 2) {
            return null;
        }

        index -= 1;
    }

    return index;
}

pub fn previous(self: LinkGrid, index: usize) ?usize {
    var result = index;
    while (result != 0) {
        if (result % self.buffer.w == 0 and !self.joins(result / self.buffer.w - 1)) {
            return null;
        }

        result -= 1;
        if (!self.padding(result)) {
            return result;
        }
    }

    return null;
}

pub fn next(self: LinkGrid, index: usize) ?usize {
    var result = index;
    while (result + 1 < self.buffer.cells.len) {
        if ((result + 1) % self.buffer.w == 0 and !self.joins(result / self.buffer.w)) {
            return null;
        }

        result += 1;
        if (!self.padding(result)) {
            return result;
        }
    }

    return null;
}

pub fn position(self: LinkGrid, index: usize) Position {
    return .{ .x = @intCast(index % self.buffer.w), .y = self.scroll.offset + @as(u32, @intCast(index / self.buffer.w)) };
}

pub fn cellEnd(self: LinkGrid, index: usize) Position {
    var result = self.position(index);
    result.x = @intCast(@min(self.buffer.w, @as(u32, result.x) + @max(1, self.buffer.cells[index].width)));
    return result;
}

fn padding(self: LinkGrid, index: usize) bool {
    const y = index / self.buffer.w;
    return y < self.rows.len and self.rows[y].wide_padding and index % self.buffer.w == self.buffer.w - 1;
}

fn joins(self: LinkGrid, row: usize) bool {
    return row + 1 < self.rows.len and self.rows[row].wrap and self.rows[row + 1].continuation;
}
