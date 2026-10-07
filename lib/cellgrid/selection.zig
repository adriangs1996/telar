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

const Point = @import("Point.zig");
const Cell = @import("Cell.zig");
const Buffer = @import("Buffer.zig");
const Range = @import("SelectionRange.zig");

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

fn isWordByte(cell: *const Cell) bool {
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

pub fn wordStart(b: *const Buffer, at: Point) u16 {
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

pub fn wordEnd(b: *const Buffer, at: Point) u16 {
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

fn cellAt(b: *const Buffer, x: u16, y: u16) ?*const Cell {
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
pub fn text(b: *const Buffer, range: Range, out: []u8) []const u8 {
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
