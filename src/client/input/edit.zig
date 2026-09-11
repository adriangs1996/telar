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

const GenericField = @import("GenericField.zig").Type;
const std = @import("std");
const measure_module = @import("telar-core").measure;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const F = GenericField(128);

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
    try std.testing.expectEqualStrings("caf" ++ e_acute, f.text());

    f.backspace();
    try std.testing.expectEqualStrings("caf", f.text());
    try std.testing.expectEqual(@as(usize, 3), f.head);
}

test "an emoji cluster is one arrow press and one backspace" {
    var f: F = .init(astronaut);
    try std.testing.expectEqual(astronaut.len, f.head);

    f.moveLeft(false);
    try std.testing.expectEqual(@as(usize, 0), f.head);
    f.moveRight(false);
    try std.testing.expectEqual(astronaut.len, f.head);

    f.backspace();
    try std.testing.expectEqualStrings("", f.text());
}

test "delete removes the cluster in front of the cursor" {
    var f: F = .init(e_acute ++ "x");
    f.home(false);
    f.delete();
    try std.testing.expectEqualStrings("x", f.text());
}

test "inserting in the middle keeps the tail" {
    var f: F = .init("ab");
    f.moveLeft(false);
    f.insert("XY");
    try std.testing.expectEqualStrings("aXYb", f.text());
    try std.testing.expectEqual(@as(usize, 3), f.head);
}

test "shift extends the selection and the anchor stays put" {
    var f: F = .init("hola");
    f.home(false);
    f.moveRight(true);
    f.moveRight(true);
    try std.testing.expectEqualStrings("ho", f.selected());
    // Shrinking from the side being dragged, which a normalised start/end pair
    // could not express.
    f.moveLeft(true);
    try std.testing.expectEqualStrings("h", f.selected());
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
    try std.testing.expect(!f.hasSelection());
    try std.testing.expectEqual(@as(usize, 0), f.head);

    f.selectAll();
    f.moveRight(false);
    try std.testing.expectEqual(@as(usize, 4), f.head);
}

test "typing over a selection replaces it" {
    var f: F = .init("hola mundo");
    f.home(false);
    for (0..4) |_| f.moveRight(true);
    f.insert("adios");
    try std.testing.expectEqualStrings("adios mundo", f.text());
    try std.testing.expect(!f.hasSelection());
}

test "backspace on a selection deletes the selection, not a character" {
    var f: F = .init("hola");
    f.selectAll();
    f.backspace();
    try std.testing.expectEqualStrings("", f.text());
}

test "word movement matches what a shell prompt does" {
    var f: F = .init("git commit --amend");
    f.moveWordLeft(false);
    try std.testing.expectEqualStrings("--amend", f.text()[f.head..]);
    f.moveWordLeft(false);
    try std.testing.expectEqualStrings("commit --amend", f.text()[f.head..]);

    f.home(false);
    f.moveWordRight(false);
    try std.testing.expectEqualStrings("git", f.text()[0..f.head]);
}

test "a paste is an insert, so it cannot behave differently from typing" {
    var f: F = .init("");
    f.insert("api key: ");
    f.insert("sk-abcdef");
    try std.testing.expectEqualStrings("api key: sk-abcdef", f.text());
}

test "input past the capacity is dropped whole, never split" {
    // Truncating mid cluster would store a fragment that renders as a
    // replacement character and cannot be deleted by one backspace.
    var f: GenericField(8) = .init("");
    f.insert("1234567");
    f.insert(astronaut);
    try std.testing.expectEqualStrings("1234567", f.text());
}

test "the view keeps the cursor on screen while typing past the edge" {
    var f: F = .init("");
    for (0..40) |_| f.insert("x");

    const v = f.view(10);
    try std.testing.expect(v.text.len <= 10);
    try std.testing.expect(v.cursor <= 10);
    try std.testing.expect(v.clipped_left);
    try std.testing.expect(!v.clipped_right);
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
    try std.testing.expectEqual(settled, f.scroll);
}

test "scrolling back left shows the start again" {
    var f: F = .init("");
    for (0..40) |_| f.insert("x");
    _ = f.view(10);
    f.home(false);
    const v = f.view(10);
    try std.testing.expectEqual(@as(u16, 0), v.cursor);
    try std.testing.expect(!v.clipped_left);
    try std.testing.expect(v.clipped_right);
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
        try std.testing.expect(measure_module(v.text) <= width);
        // Every visible byte belongs to a whole cluster.
        try std.testing.expectEqual(@as(usize, 0), v.text.len % astronaut.len);
    }
}

test "the selection reported to the drawer stays inside the window" {
    var f: F = .init("");
    for (0..40) |_| f.insert("x");
    f.selectAll();

    const v = f.view(10);
    const range = v.selection orelse return error.NoSelection;
    try std.testing.expect(range[0] <= range[1]);
    try std.testing.expect(range[1] <= 10);
}

test "cursor column is measured in columns, not bytes" {
    var f: F = .init(e_acute ++ e_acute);
    const v = f.view(20);
    // Six bytes, four codepoints, two clusters, two columns.
    try std.testing.expectEqual(@as(u16, 2), v.cursor);
}

test "an empty field views cleanly" {
    var f: F = .init("");
    const v = f.view(10);
    try std.testing.expectEqualStrings("", v.text);
    try std.testing.expectEqual(@as(u16, 0), v.cursor);
    try std.testing.expectEqual(@as(?[2]u16, null), v.selection);
    // And a zero width one does not divide by anything.
    _ = f.view(0);
}

test "movement at the edges does nothing rather than wrapping" {
    var f: F = .init("ab");
    f.home(false);
    f.moveLeft(false);
    try std.testing.expectEqual(@as(usize, 0), f.head);
    f.backspace();
    try std.testing.expectEqualStrings("ab", f.text());

    f.end(false);
    f.moveRight(false);
    try std.testing.expectEqual(@as(usize, 2), f.head);
    f.delete();
    try std.testing.expectEqualStrings("ab", f.text());
}
