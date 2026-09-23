//! A shaped label inside its parent's assigned pixel rectangle.
const Canvas = @import("Canvas.zig");
const Text = @This();

bounds: @import("../render/Rect.zig"),
label: @import("Label.zig"),

/// Example: `try label.draw(canvas);`
pub fn draw(self: Text, canvas: *Canvas) !void {
    _ = try canvas.textAt(self.bounds, self.label);
}
