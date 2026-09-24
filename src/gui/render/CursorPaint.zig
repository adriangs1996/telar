const client = @import("telar-client");
const gfx = @import("gfx");
const Color = gfx.Color;
const Rect = gfx.Rect;
const QuadList = @import("QuadList.zig");
const Paint = @This();

rect: Rect,
style: client.GuiCursor.Style,
color: Color,
text_color: Color,
thickness: f32,

/// Paints a block below ink, or another cursor shape above ink.
/// Example: `try cursor.paint(&quads);`
pub fn paint(self: Paint, quads: *QuadList) !void {
    var rect = self.rect;
    const thickness = @min(self.thickness, @min(rect.width, rect.height));
    switch (self.style) {
        .block => {
            try quads.pushRect(rect, self.color);
        },
        .bar => {
            rect.width = thickness;
            try quads.pushRect(rect, self.color);
        },
        .underline => {
            rect.y += rect.height - thickness;
            rect.height = thickness;
            try quads.pushRect(rect, self.color);
        },
        .hollow => {
            try quads.pushRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = thickness }, self.color);
            try quads.pushRect(.{ .x = rect.x, .y = rect.y + rect.height - thickness, .width = rect.width, .height = thickness }, self.color);
            try quads.pushRect(.{ .x = rect.x, .y = rect.y, .width = thickness, .height = rect.height }, self.color);
            try quads.pushRect(.{ .x = rect.x + rect.width - thickness, .y = rect.y, .width = thickness, .height = rect.height }, self.color);
        },
    }
}

/// Recolors the owning cell's ink, including overhang outside the cursor.
/// Example: `const override = cursor.inkColor(mesh.metadata.paint.rect);`
pub fn inkColor(self: Paint, anchor: Rect) ?Color {
    if (self.style == .block and anchor.x == self.rect.x and anchor.y == self.rect.y) {
        return self.text_color;
    }

    return null;
}
