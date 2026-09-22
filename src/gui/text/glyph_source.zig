//! A shaped font face or a terminal pattern drawn directly in the cell grid.
const font_id = @import("font_id.zig");
pub const Source = union(enum) {
    font: font_id.Id,
    box: @import("BoxDrawing.zig"),
    block: @import("BlockElement.zig"),
    braille: @import("Braille.zig"),
};
