const cellgrid = @import("cellgrid");
const Position = @import("Position.zig");
const path_marker = @import("path_marker.zig");
/// Walks cells in Pi's logical order: left to right, then down to the next
/// row whenever a row's reserved cursor column is reached. Rows are always
/// `width - 1` content cells wide, so any content beyond that column belongs
/// to the next row.
const Scan = @This();

buffer: *const cellgrid.Buffer,
x: u16,
y: u16,

pub fn start(buffer: *const cellgrid.Buffer) ?Scan {
    if (buffer.w < 2 or buffer.h == 0) {
        return null;
    }

    return .{
        .buffer = buffer,
        .x = 0,
        .y = 0,
    };
}

pub fn at(buffer: *const cellgrid.Buffer, origin: Position) ?Scan {
    if (buffer.w < 2 or origin.y >= buffer.h or origin.x >= buffer.w) {
        return null;
    }

    return .{
        .buffer = buffer,
        .x = origin.x,
        .y = origin.y,
    };
}

/// The current cell, or null once the screen is exhausted.
pub fn position(self: *Scan) ?Position {
    if (self.x >= self.buffer.w - 1) {
        self.x = 0;
        self.y += 1;
    }
    if (self.y >= self.buffer.h) {
        return null;
    }

    return .{
        .x = self.x,
        .y = self.y,
    };
}

pub fn cell(self: *Scan) ?*const cellgrid.Cell {
    const here = self.position() orelse return null;

    return path_marker.cellAt(
        self.buffer,
        here.x,
        here.y,
    );
}

pub fn step(self: *Scan) void {
    self.x += 1;
}

pub fn expect(self: *Scan, byte: u8) bool {
    const here = self.cell() orelse return false;
    if (!path_marker.isSingle(here) or here.text()[0] != byte) {
        return false;
    }
    self.step();

    return true;
}
