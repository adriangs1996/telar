//! One row of an agent's screen as the chrome scans read it: its ASCII text,
//! bounded, and the first visible codepoint with its column, which is where
//! agents draw their prompt marks and spinners.
const vt = @import("ghostty-vt");
const std = @import("std");
const ScreenRow = @This();

/// Longest row a scan reads; the rest is cut.
pub const max_bytes = 1024;

bytes: [max_bytes]u8 = undefined,
len: usize = 0,
first: u21 = 0,
column: usize = 0,

/// Reads row `y` of the active screen; a missing row reads empty. Non-ASCII
/// codepoints read as spaces.
///
/// ```zig
/// const row = ScreenRow.read(terminal, y);
/// ```
pub fn read(terminal: *const vt.Terminal, y: usize) ScreenRow {
    var row: ScreenRow = .{};
    const pin = terminal.screens.active.pages.pin(.{ .active = .{ .y = @intCast(y) } }) orelse return row;

    for (pin.cells(.all), 0..) |cell, x| {
        const cp = cell.codepoint();
        if (row.first == 0 and cp != 0 and cp != ' ') {
            row.first = cp;
            row.column = x;
        }

        if (row.len == row.bytes.len) {
            break;
        }

        row.bytes[row.len] = if (cp > 0 and cp < 128) @intCast(cp) else ' ';
        row.len += 1;
    }

    return row;
}

/// The row's ASCII text without surrounding spaces.
///
/// ```zig
/// if (std.mem.eql(u8, row.text(), "Working")) {}
/// ```
pub fn text(self: *const ScreenRow) []const u8 {
    return std.mem.trim(u8, self.bytes[0..self.len], " ");
}
