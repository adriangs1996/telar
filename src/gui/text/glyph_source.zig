//! A shaped font face or a terminal pattern drawn directly in the cell grid.
const cellglyphs = @import("cellglyphs");
const font_id = @import("font_id.zig");
const BoxDrawing = cellglyphs.BoxDrawing;
const BlockElement = cellglyphs.BlockElement;
const Braille = cellglyphs.Braille;
pub const Source = union(enum) {
    font: font_id.Id,
    box: BoxDrawing,
    block: BlockElement,
    braille: Braille,
};
