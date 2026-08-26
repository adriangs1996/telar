//! A single line text field.
//!
//! The whole file is one discipline: **every position is a byte offset, and
//! every movement is by grapheme cluster.** Those are two different numbers and
//! keeping them straight is the entire difficulty.
//!
//!     "e" + combining acute   3 bytes, 2 codepoints, 1 cluster, 1 column
//!     a family emoji         25 bytes, 7 codepoints, 1 cluster, 2 columns
//!
//! One press of Left moves one *cluster*. Backspace deletes one *cluster*. The
//! cursor is drawn at a *column*. And the buffer is indexed in *bytes*. Every
//! classic text field bug is one of those four quantities standing in for
//! another: a backspace that leaves half a codepoint and corrupts the line, a
//! cursor that lands between the two halves of an emoji, an arrow key that has
//! to be pressed twice on an accented letter.
//!
//! No terminal here and no allocator. A field is a string with two offsets in
//! it, which is what lets every edge case be a two line test.

const std = @import("std");
const ui = @import("telar-core").ui;

/// A fixed capacity field.
///
/// Fixed because the alternative is allocating on the keystroke path, and a
/// search box that runs out of room at 512 bytes has never been anybody's
/// problem. Input past the limit is dropped rather than truncated mid
/// character - a half written cluster is worse than a missing one.
pub fn Field(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        /// Where the cursor is, in bytes.
        head: usize = 0,
        /// Where the selection started. Equal to `head` when there is none.
        ///
        /// Kept as a separate offset rather than a start/end pair because the
        /// *direction* matters: shift-left from the middle of a selection has
        /// to shrink it from the side the user is dragging, and a normalised
        /// pair has already thrown that away.
        anchor: usize = 0,

        /// Leftmost visible byte, so the view does not jump while typing.
        scroll: usize = 0,

        pub fn init(initial: []const u8) Self {
            var f: Self = .{};
            f.setText(initial);
            return f;
        }

        pub fn setText(f: *Self, initial: []const u8) void {
            const take = @min(initial.len, capacity);
            @memcpy(f.bytes[0..take], initial[0..take]);
            f.len = take;
            f.head = take;
            f.anchor = take;
            f.scroll = 0;
        }

        pub fn text(f: *const Self) []const u8 {
            return f.bytes[0..f.len];
        }

        pub fn hasSelection(f: *const Self) bool {
            return f.head != f.anchor;
        }

        pub fn selected(f: *const Self) []const u8 {
            return f.bytes[@min(f.head, f.anchor)..@max(f.head, f.anchor)];
        }

        pub fn clearSelection(f: *Self) void {
            f.anchor = f.head;
        }

        pub fn selectAll(f: *Self) void {
            f.anchor = 0;
            f.head = f.len;
        }

        // -------------------------------------------------------------------
        // Editing
        // -------------------------------------------------------------------

        /// Inserts `input` at the cursor, replacing any selection.
        ///
        /// One path for a keystroke and for a paste, because they are the same
        /// operation and splitting them is how the two drift apart.
        pub fn insert(f: *Self, input: []const u8) void {
            _ = f.deleteSelection();
            if (f.len + input.len > capacity) return;

            const tail = f.len - f.head;
            std.mem.copyBackwards(u8, f.bytes[f.head + input.len ..][0..tail], f.bytes[f.head..][0..tail]);
            @memcpy(f.bytes[f.head..][0..input.len], input);
            f.len += input.len;
            f.head += input.len;
            f.anchor = f.head;
        }

        /// Deletes the selection, or the cluster before the cursor.
        pub fn backspace(f: *Self) void {
            if (f.deleteSelection()) return;
            const from = f.clusterBefore(f.head) orelse return;
            f.remove(from, f.head);
            f.head = from;
            f.anchor = from;
        }

        /// Deletes the selection, or the cluster at the cursor.
        pub fn delete(f: *Self) void {
            if (f.deleteSelection()) return;
            const to = f.clusterAfter(f.head) orelse return;
            f.remove(f.head, to);
        }

        fn deleteSelection(f: *Self) bool {
            if (!f.hasSelection()) return false;
            const from = @min(f.head, f.anchor);
            const to = @max(f.head, f.anchor);
            f.remove(from, to);
            f.head = from;
            f.anchor = from;
            return true;
        }

        fn remove(f: *Self, from: usize, to: usize) void {
            const tail = f.len - to;
            std.mem.copyForwards(u8, f.bytes[from..][0..tail], f.bytes[to..][0..tail]);
            f.len -= to - from;
            if (f.scroll > f.len) f.scroll = 0;
        }

        // -------------------------------------------------------------------
        // Movement
        // -------------------------------------------------------------------

        /// `extend` is whether shift was held: the anchor stays put and the
        /// selection grows, rather than collapsing to the new position.
        pub fn moveLeft(f: *Self, extend: bool) void {
            // Without shift, a left arrow on a selection collapses to its left
            // edge rather than moving from the cursor. Every editor does this
            // and it is the one movement case people notice when it is wrong.
            if (!extend and f.hasSelection()) {
                f.head = @min(f.head, f.anchor);
                f.anchor = f.head;
                return;
            }
            if (f.clusterBefore(f.head)) |from| f.head = from;
            if (!extend) f.anchor = f.head;
        }

        pub fn moveRight(f: *Self, extend: bool) void {
            if (!extend and f.hasSelection()) {
                f.head = @max(f.head, f.anchor);
                f.anchor = f.head;
                return;
            }
            if (f.clusterAfter(f.head)) |to| f.head = to;
            if (!extend) f.anchor = f.head;
        }

        pub fn home(f: *Self, extend: bool) void {
            f.head = 0;
            if (!extend) f.anchor = 0;
        }

        pub fn end(f: *Self, extend: bool) void {
            f.head = f.len;
            if (!extend) f.anchor = f.len;
        }

        /// Word movement, where a word is a run of non-space.
        ///
        /// Not Unicode word segmentation: this is what Ctrl+arrow does in a
        /// shell prompt, and matching the surrounding tools beats matching the
        /// standard when the two disagree.
        pub fn moveWordLeft(f: *Self, extend: bool) void {
            var at = f.head;
            while (at > 0 and isSpace(f.bytes[at - 1])) at -= 1;
            while (at > 0 and !isSpace(f.bytes[at - 1])) at -= 1;
            f.head = at;
            if (!extend) f.anchor = at;
        }

        pub fn moveWordRight(f: *Self, extend: bool) void {
            var at = f.head;
            while (at < f.len and isSpace(f.bytes[at])) at += 1;
            while (at < f.len and !isSpace(f.bytes[at])) at += 1;
            f.head = at;
            if (!extend) f.anchor = at;
        }

        fn isSpace(byte: u8) bool {
            return byte == ' ' or byte == '\t';
        }

        /// The byte offset of the cluster boundary before `at`.
        ///
        /// Segmentation only runs forwards, so finding the previous boundary
        /// means walking from the start. That is O(n) per left arrow, which for
        /// a field measured in tens of characters is free - and the alternative,
        /// guessing backwards from the byte pattern, is how a backspace ends up
        /// splitting a cluster it cannot see the start of.
        fn clusterBefore(f: *const Self, at: usize) ?usize {
            if (at == 0) return null;
            var it: ui.GraphemeIterator = .{ .bytes = f.text() };
            var previous: usize = 0;
            while (it.next()) |_| {
                if (it.index >= at) return previous;
                previous = it.index;
            }
            return previous;
        }

        fn clusterAfter(f: *const Self, at: usize) ?usize {
            if (at >= f.len) return null;
            var it: ui.GraphemeIterator = .{ .bytes = f.bytes[at..f.len] };
            const cluster = it.next() orelse return null;
            return at + cluster.bytes.len;
        }

        // -------------------------------------------------------------------
        // Drawing
        // -------------------------------------------------------------------

        /// What to draw, and where the cursor and selection land in it.
        pub const View = struct {
            /// The visible slice of the text.
            text: []const u8,
            /// Column within `text` where the cursor sits.
            cursor: u16,
            /// Columns the selection covers, if any, within `text`.
            selection: ?[2]u16 = null,
            /// There is text scrolled off to the left or the right.
            clipped_left: bool = false,
            clipped_right: bool = false,
        };

        /// Fits the field into `width` columns, scrolling to keep the cursor
        /// visible.
        ///
        /// The scroll offset is remembered rather than recomputed, so typing in
        /// the middle of a long value does not make the text jump around under
        /// the user. It only moves when the cursor would otherwise leave.
        pub fn view(f: *Self, width: u16) View {
            if (width == 0) return .{ .text = "", .cursor = 0 };

            // The cursor left the window on the left.
            if (f.head < f.scroll) f.scroll = f.startOfLine(f.head, width);
            // Or on the right: scroll until it fits, by clusters so the left
            // edge never lands inside one.
            while (ui.measure(f.bytes[f.scroll..f.head]) >= width) {
                const next = f.clusterAfter(f.scroll) orelse break;
                f.scroll = next;
            }

            var end_at = f.scroll;
            var used: u16 = 0;
            while (end_at < f.len) {
                const next = f.clusterAfter(end_at) orelse break;
                const cluster_width = ui.measure(f.bytes[end_at..next]);
                if (used + cluster_width > width) break;
                used += cluster_width;
                end_at = next;
            }

            const visible = f.bytes[f.scroll..end_at];
            const from = @min(f.head, f.anchor);
            const to = @max(f.head, f.anchor);
            return .{
                .text = visible,
                .cursor = ui.measure(f.bytes[f.scroll..f.head]),
                .selection = if (f.hasSelection()) .{
                    ui.measure(f.bytes[f.scroll..@max(from, f.scroll)]),
                    ui.measure(f.bytes[f.scroll..@min(@max(to, f.scroll), end_at)]),
                } else null,
                .clipped_left = f.scroll > 0,
                .clipped_right = end_at < f.len,
            };
        }

        /// Walks back from `at` until roughly `width` columns fit before it,
        /// landing on a cluster boundary.
        fn startOfLine(f: *const Self, at: usize, width: u16) usize {
            var start = at;
            while (start > 0) {
                const previous = f.clusterBefore(start) orelse break;
                if (ui.measure(f.bytes[previous..at]) > width -| 1) break;
                start = previous;
            }
            return start;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const F = Field(128);

/// A base letter plus a combining acute: one cluster, two codepoints.
const e_acute = "e\u{0301}";
/// Man + zero width joiner + rocket: one cluster, two columns, eleven bytes.
const astronaut = "\u{1F468}\u{200D}\u{1F680}";

test "typing and deleting move by cluster, not by byte" {
    // The bug this prevents: backspace takes one byte off a composed letter,
    // leaving a dangling combining mark or a broken code unit. It corrupts the
    // line rather than shortening it.
    var f: F = .init("");
    f.insert("caf");
    f.insert(e_acute);
    try testing.expectEqualStrings("caf" ++ e_acute, f.text());

    f.backspace();
    try testing.expectEqualStrings("caf", f.text());
    try testing.expectEqual(@as(usize, 3), f.head);
}

test "an emoji cluster is one arrow press and one backspace" {
    var f: F = .init(astronaut);
    try testing.expectEqual(astronaut.len, f.head);

    f.moveLeft(false);
    try testing.expectEqual(@as(usize, 0), f.head);
    f.moveRight(false);
    try testing.expectEqual(astronaut.len, f.head);

    f.backspace();
    try testing.expectEqualStrings("", f.text());
}

test "delete removes the cluster in front of the cursor" {
    var f: F = .init(e_acute ++ "x");
    f.home(false);
    f.delete();
    try testing.expectEqualStrings("x", f.text());
}

test "inserting in the middle keeps the tail" {
    var f: F = .init("ab");
    f.moveLeft(false);
    f.insert("XY");
    try testing.expectEqualStrings("aXYb", f.text());
    try testing.expectEqual(@as(usize, 3), f.head);
}

test "shift extends the selection and the anchor stays put" {
    var f: F = .init("hola");
    f.home(false);
    f.moveRight(true);
    f.moveRight(true);
    try testing.expectEqualStrings("ho", f.selected());
    // Shrinking from the side being dragged, which a normalised start/end pair
    // could not express.
    f.moveLeft(true);
    try testing.expectEqualStrings("h", f.selected());
}

test "an unshifted arrow collapses a selection to its edge" {
    // Every editor does this, and it is the movement case people notice when
    // it is wrong: the cursor jumps from the middle of the selection instead of
    // landing on its edge.
    var f: F = .init("hola");
    f.home(false);
    f.moveRight(true);
    f.moveRight(true);

    f.moveLeft(false);
    try testing.expect(!f.hasSelection());
    try testing.expectEqual(@as(usize, 0), f.head);

    f.selectAll();
    f.moveRight(false);
    try testing.expectEqual(@as(usize, 4), f.head);
}

test "typing over a selection replaces it" {
    var f: F = .init("hola mundo");
    f.home(false);
    for (0..4) |_| f.moveRight(true);
    f.insert("adios");
    try testing.expectEqualStrings("adios mundo", f.text());
    try testing.expect(!f.hasSelection());
}

test "backspace on a selection deletes the selection, not a character" {
    var f: F = .init("hola");
    f.selectAll();
    f.backspace();
    try testing.expectEqualStrings("", f.text());
}

test "word movement matches what a shell prompt does" {
    var f: F = .init("git commit --amend");
    f.moveWordLeft(false);
    try testing.expectEqualStrings("--amend", f.text()[f.head..]);
    f.moveWordLeft(false);
    try testing.expectEqualStrings("commit --amend", f.text()[f.head..]);

    f.home(false);
    f.moveWordRight(false);
    try testing.expectEqualStrings("git", f.text()[0..f.head]);
}

test "a paste is an insert, so it cannot behave differently from typing" {
    var f: F = .init("");
    f.insert("api key: ");
    f.insert("sk-abcdef");
    try testing.expectEqualStrings("api key: sk-abcdef", f.text());
}

test "input past the capacity is dropped whole, never split" {
    // Truncating mid cluster would store a fragment that renders as a
    // replacement character and cannot be deleted by one backspace.
    var f: Field(8) = .init("");
    f.insert("1234567");
    f.insert(astronaut);
    try testing.expectEqualStrings("1234567", f.text());
}

test "the view keeps the cursor on screen while typing past the edge" {
    var f: F = .init("");
    for (0..40) |_| f.insert("x");

    const v = f.view(10);
    try testing.expect(v.text.len <= 10);
    try testing.expect(v.cursor <= 10);
    try testing.expect(v.clipped_left);
    try testing.expect(!v.clipped_right);
}

test "the view does not jump around when the cursor stays put" {
    // Recomputing the scroll from scratch every frame makes a long value slide
    // under the user as they edit the middle of it.
    var f: F = .init("");
    for (0..40) |_| f.insert("x");
    _ = f.view(10);
    const settled = f.scroll;

    f.moveLeft(false);
    _ = f.view(10);
    try testing.expectEqual(settled, f.scroll);
}

test "scrolling back left shows the start again" {
    var f: F = .init("");
    for (0..40) |_| f.insert("x");
    _ = f.view(10);
    f.home(false);
    const v = f.view(10);
    try testing.expectEqual(@as(u16, 0), v.cursor);
    try testing.expect(!v.clipped_left);
    try testing.expect(v.clipped_right);
}

test "the view never cuts a wide cluster in half" {
    // A window that ends inside a two column glyph would draw one half of it,
    // and the terminal would advance past the field's edge.
    var f: F = .init("");
    for (0..10) |_| f.insert(astronaut);

    var width: u16 = 1;
    while (width <= 12) : (width += 1) {
        f.home(false);
        const v = f.view(width);
        try testing.expect(ui.measure(v.text) <= width);
        // Every visible byte belongs to a whole cluster.
        try testing.expectEqual(@as(usize, 0), v.text.len % astronaut.len);
    }
}

test "the selection reported to the drawer stays inside the window" {
    var f: F = .init("");
    for (0..40) |_| f.insert("x");
    f.selectAll();

    const v = f.view(10);
    const range = v.selection orelse return error.NoSelection;
    try testing.expect(range[0] <= range[1]);
    try testing.expect(range[1] <= 10);
}

test "cursor column is measured in columns, not bytes" {
    var f: F = .init(e_acute ++ e_acute);
    const v = f.view(20);
    // Six bytes, four codepoints, two clusters, two columns.
    try testing.expectEqual(@as(u16, 2), v.cursor);
}

test "an empty field views cleanly" {
    var f: F = .init("");
    const v = f.view(10);
    try testing.expectEqualStrings("", v.text);
    try testing.expectEqual(@as(u16, 0), v.cursor);
    try testing.expectEqual(@as(?[2]u16, null), v.selection);
    // And a zero width one does not divide by anything.
    _ = f.view(0);
}

test "movement at the edges does nothing rather than wrapping" {
    var f: F = .init("ab");
    f.home(false);
    f.moveLeft(false);
    try testing.expectEqual(@as(usize, 0), f.head);
    f.backspace();
    try testing.expectEqualStrings("ab", f.text());

    f.end(false);
    f.moveRight(false);
    try testing.expectEqual(@as(usize, 2), f.head);
    f.delete();
    try testing.expectEqualStrings("ab", f.text());
}
