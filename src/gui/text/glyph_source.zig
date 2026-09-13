//! A shaped font face or a terminal pattern drawn directly in the cell grid.
pub const Source = union(enum) {
    font: @import("font_id.zig").Id,
    box: @import("BoxDrawing.zig"),
    braille: @import("Braille.zig"),
};
