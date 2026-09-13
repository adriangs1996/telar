const client = @import("telar-client");
const Color = @import("Color.zig");
const Rect = @import("Rect.zig");
const QuadList = @import("QuadList.zig");
const Paint = @This();

rect: Rect,
style: client.GuiCursor.Style,
color: Color,
text_color: Color,
thickness: f32,

/// Paints a block below ink, or another cursor shape above ink.
/// Example: `try cursor.paint(&quads);`
pub fn paint(cursor: Paint, quads: *QuadList) !void {
    var rect = cursor.rect;
    const thickness = @min(cursor.thickness, @min(rect.width, rect.height));
    switch (cursor.style) {
        .block => {
            try quads.pushRect(rect, cursor.color);
        },
        .bar => {
            rect.width = thickness;
            try quads.pushRect(rect, cursor.color);
        },
        .underline => {
            rect.y += rect.height - thickness;
            rect.height = thickness;
            try quads.pushRect(rect, cursor.color);
        },
        .hollow => {
            try quads.pushRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = thickness }, cursor.color);
            try quads.pushRect(.{ .x = rect.x, .y = rect.y + rect.height - thickness, .width = rect.width, .height = thickness }, cursor.color);
            try quads.pushRect(.{ .x = rect.x, .y = rect.y, .width = thickness, .height = rect.height }, cursor.color);
            try quads.pushRect(.{ .x = rect.x + rect.width - thickness, .y = rect.y, .width = thickness, .height = rect.height }, cursor.color);
        },
    }
}

/// Recolors the owning cell's ink, including overhang outside the cursor.
/// Example: `const override = cursor.inkColor(mesh.paint.rect);`
pub fn inkColor(cursor: Paint, anchor: Rect) ?Color {
    if (cursor.style == .block and anchor.x == cursor.rect.x and anchor.y == cursor.rect.y) {
        return cursor.text_color;
    }

    return null;
}
