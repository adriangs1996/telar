//! Selecting text off the screen so it can be copied.
//!
//! This is the feature people actually complain about in terminal programs, and
//! the reason they complain is us: **a TUI that captures the mouse turns off the
//! terminal's own drag-to-select.** Our `enter_sequence` asks for button, drag
//! and motion reporting, so the terminal stops interpreting a drag as selection
//! and hands it to us instead. The user is left holding Shift (or Option on
//! macOS) to bypass a program that took something away and gave nothing back.
//!
//! Giving it back is not just re-implementing what the terminal did, because
//! what the terminal did was never very good: it copies *what is painted*.
//! Box borders, the gutter, a sidebar that happens to be in the way, and a
//! wrapped line broken by a newline that was never in the text.
//!
//! So the model here is in cell coordinates and knows about rows, and the
//! extraction trims what was padding rather than content. For a pane there is a
//! better source still - the emulator knows which line breaks it invented - and
//! `blit` reaches for that instead.
//!
//! No terminal and no buffer ownership: a range is four numbers and a mode.

const std = @import("std");
const ui = @import("ui/root.zig");

pub const Point = ui.Point;

/// Reading order, which is what makes a range comparable at all: a selection
/// dragged upwards has its anchor after its head.
pub fn pointBefore(a: Point, b: Point) bool {
    if (a.y != b.y) {
        return a.y < b.y;
    }

    return a.x < b.x;
}

pub const Mode = enum {
    /// Follows the text: from the anchor to the end of its row, whole rows in
    /// between, then the start of the head's row up to the head.
    linear,
    /// A rectangle. Alt-drag, and the only way to lift a column out of tabular
    /// output without taking everything around it.
    block,
};

/// What a click count means.
///
/// Character, word and line, the way every terminal and editor has behaved for
/// thirty years. Worth matching exactly: this is muscle memory, and a program
/// that gets it subtly wrong feels wrong without the user being able to say why.
pub const Granularity = enum { character, word, line };

pub const Range = @import("Range.zig");

fn isWordByte(cell: *const ui.Cell) bool {
    if (cell.width == 0) {
        return true;
    }

    const glyph = cell.text();
    if (glyph.len == 0) {
        return false;
    }
    // Anything not a space counts, including punctuation. A path or a URL is
    // what people are usually double-clicking in a terminal, and splitting it
    // at every slash makes the gesture useless.
    return glyph[0] != ' ';
}

pub fn wordStart(b: *const ui.Buffer, at: Point) u16 {
    const current = cellAt(b, at.x, at.y) orelse return at.x;
    const word = isWordByte(current);
    var x = at.x;
    while (x > 0) : (x -= 1) {
        const previous = cellAt(b, x - 1, at.y) orelse break;
        if (isWordByte(previous) != word) {
            break;
        }
    }
    return x;
}

pub fn wordEnd(b: *const ui.Buffer, at: Point) u16 {
    const current = cellAt(b, at.x, at.y) orelse return at.x;
    const word = isWordByte(current);
    var x = at.x;
    while (x + 1 < b.w) : (x += 1) {
        const next = cellAt(b, x + 1, at.y) orelse break;
        if (isWordByte(next) != word) {
            break;
        }
    }
    return x;
}

fn cellAt(b: *const ui.Buffer, x: u16, y: u16) ?*const ui.Cell {
    if (x >= b.w or y >= b.h) {
        return null;
    }
    return &b.cells[@as(usize, y) * @as(usize, b.w) + @as(usize, x)];
}

/// Copies the selected text out of `b` into `out`, returning what was written.
///
/// Two rules that separate this from reading the grid back verbatim:
///
///   - Trailing blanks on a row are padding, not content. A screen is a grid
///     and every row is full; keeping the spaces would paste a rectangle.
///   - The tail cell of a wide glyph holds nothing. Emitting it would double
///     every CJK character.
///
/// Rows are joined with a newline. That newline is real for chrome, which was
/// never one long line - unlike a pane, where the emulator knows which breaks
/// it invented and `blit` asks it instead.
pub fn text(b: *const ui.Buffer, range: Range, out: []u8) []const u8 {
    if (range.isEmpty()) {
        return out[0..0];
    }

    const from, const to = range.ordered();
    var len: usize = 0;
    var y = from.y;
    while (y <= to.y and y < b.h) : (y += 1) {
        // Where this row's content ends, ignoring padding.
        var end: ?u16 = null;
        var x: u16 = 0;
        while (x < b.w) : (x += 1) {
            if (!range.contains(x, y)) {
                continue;
            }
            const cell = cellAt(b, x, y) orelse continue;
            if (cell.width == 0) {
                continue;
            }
            if (isWordByte(cell)) {
                end = x;
            }
        }

        if (end) |last| {
            x = 0;
            while (x <= last) : (x += 1) {
                if (!range.contains(x, y)) {
                    continue;
                }
                const cell = cellAt(b, x, y) orelse continue;
                if (cell.width == 0) {
                    continue;
                }
                const bytes = cell.text();
                if (len + bytes.len > out.len) {
                    return out[0..len];
                }
                @memcpy(out[len..][0..bytes.len], bytes);
                len += bytes.len;
            }
        }

        if (y < to.y) {
            if (len + 1 > out.len) {
                return out[0..len];
            }
            out[len] = '\n';
            len += 1;
        }
    }
    return out[0..len];
}

pub const ClickTracker = @import("ClickTracker.zig");

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Draws `rows` into a buffer, so the tests read like a screen.
fn screen(gpa: std.mem.Allocator, rows: []const []const u8) !ui.Buffer {
    var width: u16 = 0;
    for (rows) |row| width = @max(width, ui.measure(row));
    var b = try ui.Buffer.init(gpa, width, @intCast(rows.len));
    b.fill(b.area(), .{ .glyph = " ", .style = .{} });
    for (rows, 0..) |row, y| _ = b.writeText(b.area(), .{ .point = .{ .x = 0, .y = @intCast(y) }, .text = row, .style = .{} });
    return b;
}

fn copied(b: *const ui.Buffer, range: Range, out: []u8) []const u8 {
    return text(b, range.expanded(b), out);
}

test "a linear selection follows the text, not a rectangle" {
    // Dragging from the middle of one row to the middle of another takes the
    // rest of the first row and the start of the last, which is what reading
    // order means and what a rectangle would get wrong.
    const gpa = testing.allocator;
    var b = try screen(gpa, &.{ "abcdef", "ghijkl", "mnopqr" });
    defer b.deinit();

    var out: [64]u8 = undefined;
    const got = copied(&b, .{ .anchor = .{ .x = 3, .y = 0 }, .head = .{ .x = 2, .y = 2 } }, &out);
    try testing.expectEqualStrings("def\nghijkl\nmno", got);
}

test "a block selection lifts a column out" {
    // The reason block mode is worth having: pulling one column out of tabular
    // output without dragging everything around it along.
    const gpa = testing.allocator;
    var b = try screen(gpa, &.{ "aa bb cc", "dd ee ff", "gg hh ii" });
    defer b.deinit();

    var out: [64]u8 = undefined;
    const got = copied(&b, .{
        .anchor = .{ .x = 3, .y = 0 },
        .head = .{ .x = 4, .y = 2 },
        .mode = .block,
    }, &out);
    try testing.expectEqualStrings("bb\nee\nhh", got);
}

test "a selection dragged upwards is the same selection" {
    const gpa = testing.allocator;
    var b = try screen(gpa, &.{ "abc", "def" });
    defer b.deinit();

    var down: [32]u8 = undefined;
    var up: [32]u8 = undefined;
    const forwards = copied(&b, .{ .anchor = .{ .x = 1, .y = 0 }, .head = .{ .x = 1, .y = 1 } }, &down);
    const backwards = copied(&b, .{ .anchor = .{ .x = 1, .y = 1 }, .head = .{ .x = 1, .y = 0 } }, &up);
    try testing.expectEqualStrings(forwards, backwards);
}

test "trailing padding is not content" {
    // A screen is a grid and every row is full. Copying the blanks pastes a
    // rectangle of spaces, which is the single most recognisable symptom of
    // text copied out of a terminal.
    const gpa = testing.allocator;
    var b = try screen(gpa, &.{ "hi", "there" });
    defer b.deinit();

    var out: [32]u8 = undefined;
    const got = copied(&b, .{ .anchor = .{ .x = 0, .y = 0 }, .head = .{ .x = 4, .y = 1 } }, &out);
    try testing.expectEqualStrings("hi\nthere", got);
}

test "a wide glyph is copied once, not twice" {
    // Its second cell holds nothing. Reading the grid back verbatim doubles
    // every CJK character.
    const gpa = testing.allocator;
    var b = try screen(gpa, &.{"漢字"});
    defer b.deinit();

    var out: [32]u8 = undefined;
    const got = copied(&b, .{ .anchor = .{ .x = 0, .y = 0 }, .head = .{ .x = 3, .y = 0 } }, &out);
    try testing.expectEqualStrings("漢字", got);
}

test "double click on a one-character word selects that character" {
    // Expansion of a single-cell word collapses anchor and head onto the same
    // point; that must still read as one selected cell, not as no selection.
    const gpa = testing.allocator;
    var b = try screen(gpa, &.{"run x now"});
    defer b.deinit();

    var out: [16]u8 = undefined;
    const got = copied(&b, .{
        .anchor = .{ .x = 4, .y = 0 },
        .head = .{ .x = 4, .y = 0 },
        .granularity = .word,
    }, &out);
    try testing.expectEqualStrings("x", got);
}

test "double click takes the word, including its punctuation" {
    // A path or a URL is what people double-click in a terminal. Splitting at
    // every slash makes the gesture useless.
    const gpa = testing.allocator;
    var b = try screen(gpa, &.{"run src/main.zig now"});
    defer b.deinit();

    var out: [64]u8 = undefined;
    const got = copied(&b, .{
        .anchor = .{ .x = 7, .y = 0 },
        .head = .{ .x = 7, .y = 0 },
        .granularity = .word,
    }, &out);
    try testing.expectEqualStrings("src/main.zig", got);
}

test "triple click takes the row without its padding" {
    const gpa = testing.allocator;
    var b = try screen(gpa, &.{ "short", "a much longer row" });
    defer b.deinit();

    var out: [64]u8 = undefined;
    const got = copied(&b, .{
        .anchor = .{ .x = 2, .y = 0 },
        .head = .{ .x = 2, .y = 0 },
        .granularity = .line,
    }, &out);
    try testing.expectEqualStrings("short", got);
}

test "word granularity survives a drag" {
    // Double-click-and-drag selects by word all the way along. People rely on
    // it without knowing it exists, and it only works if the expansion is
    // applied on every move rather than once at the start.
    const gpa = testing.allocator;
    var b = try screen(gpa, &.{"alpha beta gamma"});
    defer b.deinit();

    var out: [64]u8 = undefined;
    const got = copied(&b, .{
        .anchor = .{ .x = 7, .y = 0 },
        .head = .{ .x = 12, .y = 0 },
        .granularity = .word,
    }, &out);
    try testing.expectEqualStrings("beta gamma", got);
}

test "highlighting agrees with what gets copied" {
    // Two code paths, one answer. A selection that paints wider than it copies
    // is the kind of thing users notice and cannot describe.
    const gpa = testing.allocator;
    var b = try screen(gpa, &.{ "abcdef", "ghijkl" });
    defer b.deinit();

    const range: Range = .{ .anchor = .{ .x = 4, .y = 0 }, .head = .{ .x = 1, .y = 1 } };
    var out: [64]u8 = undefined;
    const got = copied(&b, range, &out);

    var painted: usize = 0;
    for (0..b.h) |y| for (0..b.w) |x| {
        if (range.contains(@intCast(x), @intCast(y))) {
            painted += 1;
        }
    };
    // "ef" + newline + "gh": four characters painted, four copied plus the
    // break the rows imply.
    try testing.expectEqual(@as(usize, 4), painted);
    try testing.expectEqualStrings("ef\ngh", got);
}

test "word expansion groups whitespace separately and keeps wide glyph tails inside words" {
    var b = try screen(testing.allocator, &.{"ab  界cd"});
    defer b.deinit();
    const space = (Range{ .anchor = .{ .x = 2, .y = 0 }, .head = .{ .x = 2, .y = 0 }, .granularity = .word }).expanded(&b);
    try testing.expectEqual(@as(u16, 2), space.anchor.x);
    try testing.expectEqual(@as(u16, 3), space.head.x);
    const wide = (Range{ .anchor = .{ .x = 5, .y = 0 }, .head = .{ .x = 5, .y = 0 }, .granularity = .word }).expanded(&b);
    try testing.expectEqual(@as(u16, 4), wide.anchor.x);
    try testing.expectEqual(@as(u16, 7), wide.head.x);
}

test "rapid repeated clicks saturate at line granularity" {
    var tracker: ClickTracker = .{};
    for (0..1024) |index| {
        const granularity = tracker.press(.{ .x = 2, .y = 3 }, index);
        if (index >= 2) {
            try testing.expectEqual(Granularity.line, granularity);
        }
    }
}

test "an empty selection copies nothing" {
    const gpa = testing.allocator;
    var b = try screen(gpa, &.{"abc"});
    defer b.deinit();

    var out: [32]u8 = undefined;
    const got = copied(&b, .{ .anchor = .{ .x = 1, .y = 0 }, .head = .{ .x = 1, .y = 0 } }, &out);
    try testing.expectEqualStrings("", got);
}

test "extraction stops at the end of the caller's buffer" {
    // The output size is the caller's choice and a screen can be large. Running
    // past it would be the one memory bug in a file that has no allocator.
    const gpa = testing.allocator;
    var b = try screen(gpa, &.{ "aaaaaaaaaa", "bbbbbbbbbb" });
    defer b.deinit();

    var out: [5]u8 = undefined;
    const got = copied(&b, .{ .anchor = .{ .x = 0, .y = 0 }, .head = .{ .x = 9, .y = 1 } }, &out);
    try testing.expect(got.len <= out.len);
    try testing.expectEqualStrings("aaaaa", got);
}

test "clicks become double and triple only when they are close in both senses" {
    var t: ClickTracker = .{};
    const at: Point = .{ .x = 4, .y = 2 };

    try testing.expectEqual(Granularity.character, t.press(at, 0));
    try testing.expectEqual(Granularity.word, t.press(at, 100 * std.time.ns_per_ms));
    try testing.expectEqual(Granularity.line, t.press(at, 200 * std.time.ns_per_ms));
    // Past three it stays on line: holding the button down asks for more, never
    // for less.
    try testing.expectEqual(Granularity.line, t.press(at, 300 * std.time.ns_per_ms));

    // Too slow.
    try testing.expectEqual(Granularity.character, t.press(at, 2000 * std.time.ns_per_ms));
    // Quick, but somewhere else. Two clicks far apart are two clicks.
    try testing.expectEqual(
        Granularity.character,
        t.press(.{ .x = 40, .y = 9 }, 2050 * std.time.ns_per_ms),
    );
}

test "a click one column over still counts as a double click" {
    // Fingers move. Demanding the exact same cell makes double click fail often
    // enough to feel unreliable without ever failing reproducibly.
    var t: ClickTracker = .{};
    try testing.expectEqual(Granularity.character, t.press(.{ .x = 4, .y = 2 }, 0));
    try testing.expectEqual(Granularity.word, t.press(.{ .x = 5, .y = 2 }, 50 * std.time.ns_per_ms));
}
