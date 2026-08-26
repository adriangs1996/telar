//! Frontend UI facade.
//!
//! Cells and buffers come from core because they cross the process boundary.
//! Hit testing and focus exist only while a client is attached.

const shared = @import("telar-core").ui;
const hits = @import("hits.zig");
const focus = @import("focus.zig");

pub const theme = @import("theme.zig");
pub const icons = @import("icons.zig");

pub const Rect = shared.Rect;

pub const Color = shared.Color;
pub const Style = shared.Style;
pub const Cell = shared.Cell;

pub const measure = shared.measure;
pub const GraphemeIterator = shared.GraphemeIterator;

pub const Buffer = shared.Buffer;

pub const Hits = hits.Hits;
pub const Focus = focus.Focus;

test {
    @import("std").testing.refAllDecls(@This());
    _ = hits;
    _ = focus;
}
