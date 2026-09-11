const BufferType = @import("telar-core").Buffer;
const Position = @import("Position.zig");
const CellType = @import("telar-core").Cell;
const path_marker = @import("path_marker.zig");
/// Walks cells in Pi's logical order: left to right, then down to the next
/// row whenever a row's reserved cursor column is reached. Rows are always
/// `width - 1` content cells wide, so any content beyond that column belongs
/// to the next row.
const Scan = @This();

buffer: *const BufferType,
x: u16,
y: u16,

pub fn start(buffer: *const BufferType) ?Scan {
    if (buffer.w < 2 or buffer.h == 0) {
        return null;
    }

    return .{ .buffer = buffer, .x = 0, .y = 0 };
}

pub fn at(buffer: *const BufferType, origin: Position) ?Scan {
    if (buffer.w < 2 or origin.y >= buffer.h or origin.x >= buffer.w) {
        return null;
    }

    return .{ .buffer = buffer, .x = origin.x, .y = origin.y };
}

/// The current cell, or null once the screen is exhausted.
pub fn position(scan: *Scan) ?Position {
    if (scan.x >= scan.buffer.w - 1) {
        scan.x = 0;
        scan.y += 1;
    }
    if (scan.y >= scan.buffer.h) {
        return null;
    }

    return .{ .x = scan.x, .y = scan.y };
}

pub fn cell(scan: *Scan) ?*const CellType {
    const here = scan.position() orelse return null;

    return path_marker.cellAt(scan.buffer, here.x, here.y);
}

pub fn step(scan: *Scan) void {
    scan.x += 1;
}

pub fn expect(scan: *Scan, byte: u8) bool {
    const here = scan.cell() orelse return false;
    if (!path_marker.isSingle(here) or here.text()[0] != byte) {
        return false;
    }
    scan.step();

    return true;
}
