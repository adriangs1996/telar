//! The drawing layer, from the bottom up.
//!
//! ratatui is three things stacked, and only the middle one is shared:
//!
//!   1. a grid of cells you draw into, with no memory of the terminal
//!   2. a diff between the grid you just drew and the one on screen
//!   3. widgets, which are only functions that write into a region of (1)
//!
//! Everything a user experiences as "the UI" is (3), and (3) needs no
//! framework: a widget is `fn (buf: *Buffer, area: Rect, ...) void`. What has
//! to exist is (2), because writing the whole screen every frame is what makes
//! a terminal application feel slow. The frontend owns that diff.
//!
//! This file is a facade. Every name below is defined in the file named beside
//! it, which is what keeps any one of them from growing into the object that
//! knows everything:
//!
//!   `geometry`  rectangles and the arithmetic on them
//!   `cell`      colours, styles, one screen position
//!   `text`      how many columns a string occupies
//!   `buffer`    the grid, clipping, and drawing into it
//!
//! The frontend adds hit testing and focus to this facade. Backend code sees
//! only the shared names below.

const geometry = @import("ui/geometry.zig");
const cell = @import("ui/cell.zig");
const text = @import("ui/text.zig");
const buffer = @import("ui/buffer.zig");

pub const Rect = geometry.Rect;

pub const Color = cell.Color;
pub const Style = cell.Style;
pub const Cell = cell.Cell;

pub const measure = text.measure;
pub const GraphemeIterator = text.GraphemeIterator;

pub const Buffer = buffer.Buffer;

test {
    @import("std").testing.refAllDecls(@This());
    _ = geometry;
    _ = cell;
    _ = text;
    _ = buffer;
}
