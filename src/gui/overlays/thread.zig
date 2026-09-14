//! Compatibility entrypoint for isolated thread-rendering probes.
const Canvas = @import("../chrome/Canvas.zig");
const client = @import("telar-client");
const core = @import("telar-core");

/// Example: `try paint(canvas, area, thread);`
pub fn paint(canvas: *Canvas, area: core.Rect, thread: client.ThreadView) !void {
    try (@import("../widgets/ThreadPane.zig"){ .area = area, .thread = thread }).draw(canvas);
}
