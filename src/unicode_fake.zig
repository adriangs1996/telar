//! A width table that answers nonsense on purpose.
//!
//! Bound to the `unicode` module name for one test target. If the drawing layer
//! really takes its widths from the provider, ASCII laid out by this file
//! occupies two columns per character and the layout shifts accordingly. If it
//! secretly assumes one column per byte anywhere, that test fails - which is
//! the only way to tell a seam from a comment claiming there is one.

pub const Measured = struct { len: usize, width: u8 };

pub fn graphemeWidth(codepoints: []const u21) Measured {
    if (codepoints.len == 0) return .{ .len = 0, .width = 0 };
    return .{ .len = 1, .width = 2 };
}
