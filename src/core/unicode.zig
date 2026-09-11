//! Where column widths come from.
//!
//! This file exists to be replaced. `ui` imports it by *module name*, not by
//! path, so a build can point that name at a different implementation without
//! touching a line of drawing code - which is what keeps the drawing layer
//! extractable as a library that does not drag a terminal emulator behind it.
//!
//! The default is deliberately not a general Unicode library. Telar draws its
//! chrome flush against panes that libghostty-vt laid out, and two disagreeing
//! width tables produce a UI that slides one column at a time until a box
//! border lands in the middle of a name. Asking the emulator that will render
//! the output is the only answer guaranteed to agree with what appears on
//! screen, so substituting this is a decision to accept that risk, taken by
//! someone who has a reason - a build with no emulator in it, or a test that
//! wants to fix the widths rather than look them up.

const UnicodeMeasured = @import("UnicodeMeasured.zig");
const vt = @import("ghostty-vt");

/// Measures the first grapheme cluster in `codepoints`.
///
/// Segmentation and width in one call, on purpose: they are the same table
/// lookup, and splitting them is how a measurement and a draw come to disagree.
pub fn graphemeWidth(codepoints: []const u21) UnicodeMeasured {
    const measured = vt.unicode.graphemeWidth(u21, codepoints);
    return .{ .len = measured.len, .width = @intCast(measured.width) };
}
