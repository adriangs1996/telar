//! A filled rounded surface, usable in any frame's widget union.
const Canvas = @import("Canvas.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const RoundedFill = @import("RoundedFill.zig");
const Surface = @This();

bounds: Rect,
fill: RoundedFill,

/// Example: `try surface.draw(canvas);`
pub fn draw(self: Surface, canvas: *Canvas) !void {
    try canvas.fillRoundedAt(self.bounds, self.fill);
}
