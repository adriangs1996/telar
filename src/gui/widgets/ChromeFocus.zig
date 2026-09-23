//! Drawn after chrome controls so focus uses their newly prepared rectangles.
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Chrome = @import("Chrome.zig");
const ChromeFocus = @This();

chrome: *Chrome,
projection: *const client.Projection,

/// Registers the painted controls and outlines the focused one before overlays.
/// Example: `try focus.draw(canvas);`
pub fn draw(self: ChromeFocus, canvas: *Canvas) !void {
    if (canvas.widgets) |state| {
        try state.chrome(canvas, .{ .chrome = self.chrome, .projection = self.projection });
    }
}
