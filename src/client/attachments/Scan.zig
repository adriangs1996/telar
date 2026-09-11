/// Walks cells in Pi's logical order: left to right, then down to the next
/// row whenever a row's reserved cursor column is reached. Rows are always
/// `width - 1` content cells wide, so any content beyond that column belongs
/// to the next row.
const Scan = @This();
const source_namespace = @import("path_marker.zig");
const Position = @import("Position.zig");
buffer: *const source_namespace.ui.Buffer,
x: u16,
y: u16,

pub fn start(buffer: *const source_namespace.ui.Buffer) ?Scan {
    if (buffer.w < 2 or buffer.h == 0) {
        return null;
    }

    return .{ .buffer = buffer, .x = 0, .y = 0 };
}

pub fn at(buffer: *const source_namespace.ui.Buffer, origin: Position) ?Scan {
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

pub fn cell(scan: *Scan) ?*const source_namespace.ui.Cell {
    const here = scan.position() orelse return null;

    return source_namespace.cellAt(scan.buffer, here.x, here.y);
}

pub fn step(scan: *Scan) void {
    scan.x += 1;
}

pub fn expect(scan: *Scan, byte: u8) bool {
    const here = scan.cell() orelse return false;
    if (!source_namespace.isSingle(here) or here.text()[0] != byte) {
        return false;
    }
    scan.step();

    return true;
}
