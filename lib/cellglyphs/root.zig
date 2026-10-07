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
