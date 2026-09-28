//! The headless client's stdin protocol: one command per line.
//!
//! ```text
//! key enter          a key or chord: `a`, `ctrl+c`, `alt+x`, `shift+tab`, `up`
//! text echo hello    characters typed in order, UTF-8
//! resize 120x40      the host grid in cells
//! mark sent-3        a labelled timestamp in the exit trace
//! notification activate  click the newest notification
//! quit               leave; the end of stdin does the same
//! ```
//!
//! It is not a terminal escape parser: every line names what a host would
//! have delivered as semantic keys.
const keyinput = @import("keyinput");
const std = @import("std");
const InputLine = @import("InputLine.zig").InputLine;
const InputText = @import("InputText.zig");
const InputLabel = @import("InputLabel.zig");
const InputSize = @import("InputSize.zig");

/// The longest line the protocol accepts, in bytes.
pub const max_line_bytes = InputText.max_bytes + 16;
/// The widest grid a `resize` may ask for.
const max_cells: u16 = 1000;

/// Parses one line without its newline.
///
/// ```zig
/// const line = try input_protocol.parse("key ctrl+c");
/// ```
pub fn parse(line: []const u8) !InputLine {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    const space = std.mem.indexOfScalar(u8, trimmed, ' ');
    const word = trimmed[0 .. space orelse trimmed.len];
    const rest = if (space) |at| trimmed[at + 1 ..] else "";

    if (std.mem.eql(u8, word, "key")) {
        return .{ .key = try keyinput.chord.parseKey(rest) };
    }

    if (std.mem.eql(u8, word, "text")) {
        if (rest.len > InputText.max_bytes or !std.unicode.utf8ValidateSlice(rest)) {
            return error.InvalidHeadlessText;
        }

        var text: InputText = .{ .len = @intCast(rest.len) };
        @memcpy(text.bytes[0..rest.len], rest);
        return .{ .text = text };
    }

    if (std.mem.eql(u8, word, "resize")) {
        return .{ .resize = try parseSize(rest) };
    }

    if (std.mem.eql(u8, word, "mark")) {
        if (rest.len == 0 or rest.len > InputLabel.max_bytes) {
            return error.InvalidHeadlessLabel;
        }

        var label: InputLabel = .{ .len = @intCast(rest.len) };
        @memcpy(label.bytes[0..rest.len], rest);
        return .{ .mark = label };
    }

    if (std.mem.eql(u8, word, "quit") and rest.len == 0) {
        return .quit;
    }

    if (std.mem.eql(u8, word, "notification") and std.mem.eql(u8, rest, "activate")) {
        return .notification_activate;
    }

    return error.UnknownHeadlessCommand;
}

/// Parses `COLSxROWS`, as `resize` and `--size` take it.
///
/// ```zig
/// const size = try input_protocol.parseSize("120x40");
/// ```
pub fn parseSize(text: []const u8) !InputSize {
    const at = std.mem.indexOfScalar(u8, text, 'x') orelse return error.InvalidHeadlessSize;
    const cols = std.fmt.parseInt(u16, text[0..at], 10) catch return error.InvalidHeadlessSize;
    const rows = std.fmt.parseInt(u16, text[at + 1 ..], 10) catch return error.InvalidHeadlessSize;
    if (cols == 0 or rows == 0 or cols > max_cells or rows > max_cells) {
        return error.InvalidHeadlessSize;
    }

    return .{
        .cols = cols,
        .rows = rows,
    };
}

test "lines name keys, text, sizes and marks" {
    const chord = try parse("key ctrl+c");
    try std.testing.expect(chord.key.isCtrl('c'));
    try std.testing.expect((try parse("key enter")).key.code == .enter);

    const typed = try parse("text echo ñ");
    try std.testing.expectEqualStrings("echo ñ", typed.text.slice());

    const size = (try parse("resize 120x40\r")).resize;
    try std.testing.expectEqual(@as(u16, 120), size.cols);
    try std.testing.expectEqual(@as(u16, 40), size.rows);

    try std.testing.expectEqualStrings("sent-3", (try parse("mark sent-3")).mark.slice());
    try std.testing.expect(try parse("quit") == .quit);
    try std.testing.expect(try parse("notification activate") == .notification_activate);
}

test "malformed lines are refused" {
    try std.testing.expectError(error.UnknownHeadlessCommand, parse("type x"));
    try std.testing.expectError(error.UnknownHeadlessCommand, parse("notification dismiss"));
    try std.testing.expectError(error.InvalidHeadlessSize, parse("resize 0x10"));
    try std.testing.expectError(error.InvalidHeadlessSize, parse("resize 10"));
    try std.testing.expectError(error.InvalidHeadlessLabel, parse("mark "));
    try std.testing.expectError(error.InvalidHeadlessText, parse("text \xff"));
}
