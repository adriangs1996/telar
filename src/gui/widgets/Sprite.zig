//! An image reference and its placement; the renderer owns the texture page.
const Canvas = @import("../chrome/Canvas.zig");
const Sprite = @This();

bounds: @import("../render/Rect.zig"),
paint: @import("../chrome/SpritePaint.zig"),

/// Example: `try mascot.draw(canvas);`
pub fn draw(sprite: Sprite, canvas: *Canvas) !void {
    try canvas.spriteTintedAt(sprite.bounds, sprite.paint);
}
