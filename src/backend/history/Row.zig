const vt = @import("ghostty-vt");
const std = @import("std");
const Row = @This();

bytes: [1024]u8 = undefined,
len: usize = 0,
first: u21 = 0,
column: usize = 0,

pub fn read(terminal: *const vt.Terminal, y: usize) Row {
    var row: Row = .{};
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

pub fn text(row: *const Row) []const u8 {
    return std.mem.trim(u8, row.bytes[0..row.len], " ");
}

pub fn isStatus(row: *const Row) bool {
    const line = row.text();
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return false;
    const heading = std.mem.trim(u8, line[0..open], " ");
    const spinner = row.first == 0x2022 or (row.first >= 0x2800 and row.first <= 0x28ff);
    if (!spinner and !std.mem.eql(u8, heading, "Working") and !std.mem.eql(u8, heading, "Thinking") and !std.mem.eql(u8, heading, "Reconnecting") and !std.mem.eql(u8, heading, "Compacting")) {
        return false;
    }

    // A clock is part of the live status contract, including when the
    // interrupt shortcut is remapped, hidden, or clipped by a narrow pane.
    var index = open + 1;
    const digits = index;
    while (index < line.len and std.ascii.isDigit(line[index])) : (index += 1) {}
    if (index == digits or index == line.len) {
        return false;
    }

    return line[index] == 's' or line[index] == 'm' or line[index] == 'h';
}
