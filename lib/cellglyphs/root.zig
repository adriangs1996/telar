//! Terminal glyphs drawn from geometry instead of a font, so they meet every
//! cell edge at any size: box drawing strokes with their curves rasterized,
//! block elements and shades, and Braille dots. Each paints solid rectangles
//! into a `gfx.QuadList` given the cell's rectangle.

pub const BlockElement = @import("BlockElement.zig");
pub const BlockInk = @import("BlockInk.zig");
pub const BoxCurve = @import("BoxCurve.zig");
pub const BoxDrawing = @import("BoxDrawing.zig");
pub const BoxGrid = @import("BoxGrid.zig");
pub const BoxInk = @import("BoxInk.zig");
pub const BoxRaster = @import("BoxRaster.zig");
pub const Braille = @import("Braille.zig");

test {
    _ = @import("BlockElement.zig");
    _ = @import("BlockInk.zig");
    _ = @import("BlockSlab.zig");
    _ = @import("BoxCurve.zig");
    _ = @import("BoxDrawing.zig");
    _ = @import("BoxGrid.zig");
    _ = @import("BoxInk.zig");
    _ = @import("BoxLines.zig");
    _ = @import("BoxRaster.zig");
    _ = @import("Braille.zig");
    _ = @import("BrailleGrid.zig");
    _ = @import("block_shapes.zig");
    _ = @import("box_lines.zig");
    _ = @import("box_style.zig");
}
