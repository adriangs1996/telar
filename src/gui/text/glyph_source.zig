//! A shaped font face or a terminal pattern drawn directly in the cell grid.
const font_id = @import("font_id.zig");
const BoxDrawing = @import("BoxDrawing.zig");
const BlockElement = @import("BlockElement.zig");
const Braille = @import("Braille.zig");
pub const Source = union(enum) {
    font: font_id.Id,
    box: BoxDrawing,
    block: BlockElement,
    braille: Braille,
};
