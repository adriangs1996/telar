//! The drawing layer, from the bottom up.
//!
//! ratatui is three things stacked, and only the middle one is interesting:
//!
//!   1. a grid of cells you draw into, with no memory of the terminal
//!   2. a diff between the grid you just drew and the one on screen
//!   3. widgets, which are only functions that write into a region of (1)
//!
//! Everything a user experiences as "the UI" is (3), and (3) needs no
//! framework: a widget is `fn (buf: *Buffer, area: Rect, ...) void`. What has
//! to exist is (2), because writing the whole screen every frame is what makes
//! a terminal application feel slow - and that lives in `term`, next door.
//!
//! This file is a facade. Every name below is defined in the file named beside
//! it, which is what keeps any one of them from growing into the object that
//! knows everything:
//!
//!   `geometry`  rectangles and the arithmetic on them
//!   `cell`      colours, styles, one screen position
//!   `text`      how many columns a string occupies
//!   `buffer`    the grid, clipping, and drawing into it
//!   `hits`      what was clickable, and which layer it was on
//!   `focus`     who has the keyboard
//!
//! Consumers import `ui` and never the parts, so the split can be revised
//! without touching a call site.

const geometry = @import("ui/geometry.zig");
const cell = @import("ui/cell.zig");
const text = @import("ui/text.zig");
const buffer = @import("ui/buffer.zig");
const hits = @import("ui/hits.zig");
const focus = @import("ui/focus.zig");

pub const Rect = geometry.Rect;

pub const Color = cell.Color;
pub const Style = cell.Style;
pub const Cell = cell.Cell;

pub const measure = text.measure;
pub const GraphemeIterator = text.GraphemeIterator;

pub const Buffer = buffer.Buffer;

pub const Hits = hits.Hits;
pub const Focus = focus.Focus;

test {
    @import("std").testing.refAllDecls(@This());
    _ = geometry;
    _ = cell;
    _ = text;
    _ = buffer;
    _ = hits;
    _ = focus;
}
