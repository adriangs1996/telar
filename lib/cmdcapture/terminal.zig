//! Shell-independent command capture from the PTY's rendered terminal state.

const std = @import("std");
const vt = @import("ghostty-vt");

pub const max_output_tail_bytes = 64 * 1024;

pub fn validPrefixLength(bytes: []const u8, limit: usize) usize {
    if (bytes.len <= limit) {
        return bytes.len;
    }
    var len = limit;
    while (len > 0 and !std.unicode.utf8ValidateSlice(bytes[0..len])) : (len -= 1) {}
    return len;
}

pub fn rowIsBlank(pin: vt.Pin) bool {
    return cellsBlank(pin.cells(.all));
}

pub fn cellsBlank(cells: []const vt.Cell) bool {
    for (cells) |cell| {
        if (!cellBlank(cell)) {
            return false;
        }
    }
    return true;
}

pub fn cellBlank(cell: vt.Cell) bool {
    return !cell.hasText() or cell.codepoint() == ' ';
}

pub fn hashCells(cells: []const vt.Cell) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (cells) |cell| {
        hash ^= @as(u64, @bitCast(cell));
        hash *%= 0x100000001b3;
    }
    return hash;
}
