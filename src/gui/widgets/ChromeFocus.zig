//! Drawn after chrome controls so focus uses their newly prepared rectangles.
const Canvas = @import("Canvas.zig");
const ChromeFocus = @This();

chrome: *@import("Chrome.zig"),
projection: *const @import("telar-client").Projection,

/// Registers the painted controls and outlines the focused one before overlays.
/// Example: `try focus.draw(canvas);`
pub fn draw(widget: ChromeFocus, canvas: *Canvas) !void {
    if (canvas.widgets) |state| {
        try state.chrome(canvas, .{ .chrome = widget.chrome, .projection = widget.projection });
    }
}
