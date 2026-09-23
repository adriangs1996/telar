//! An image reference and its placement; the renderer owns the texture page.
const Canvas = @import("Canvas.zig");
const Sprite = @This();

bounds: @import("../render/Rect.zig"),
paint: @import("SpritePaint.zig"),

/// Example: `try mascot.draw(canvas);`
pub fn draw(self: Sprite, canvas: *Canvas) !void {
    try canvas.spriteTintedAt(self.bounds, self.paint);
}
