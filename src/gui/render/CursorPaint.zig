const client = @import("telar-client");
const Color = @import("Color.zig");
const Rect = @import("Rect.zig");
const Quad = @import("Quad.zig").Quad;
const QuadList = @import("QuadList.zig");
const Paint = @This();

rect: Rect,
style: client.GuiCursor.Style,
color: Color,
text_color: Color,
thickness: f32,
ink: []const Quad,

/// Paints over retained ink without shaping or modifying the cell cache.
/// Example: `try cursor.paint(&quads);`
pub fn paint(cursor: Paint, quads: *QuadList) !void {
    var rect = cursor.rect;
    const thickness = @min(cursor.thickness, @min(rect.width, rect.height));
    switch (cursor.style) {
        .block => {
            try quads.pushRect(rect, cursor.color);
            for (cursor.ink) |original| {
                var glyph = original;
                glyph.r = cursor.text_color.r;
                glyph.g = cursor.text_color.g;
                glyph.b = cursor.text_color.b;
                glyph.a = cursor.text_color.a;
                try quads.push(glyph);
            }
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
