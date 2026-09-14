//! A filled rounded surface, usable in any frame's widget union.
const Canvas = @import("Canvas.zig");
const Surface = @This();

bounds: @import("../render/Rect.zig"),
fill: @import("RoundedFill.zig"),

/// Example: `try surface.draw(canvas);`
pub fn draw(surface: Surface, canvas: *Canvas) !void {
    try canvas.fillRoundedAt(surface.bounds, surface.fill);
}
