//! A single line text field of fixed capacity.
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

pub const GenericField = @import("GenericField.zig").Type;

test {
    _ = @import("GenericField.zig");
    _ = @import("field_tests.zig");
}
