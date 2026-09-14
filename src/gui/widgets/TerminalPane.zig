//! One visible terminal leaf, borrowed only until its synchronous draw ends.
const Canvas = @import("../chrome/Canvas.zig");
const TerminalPane = @This();

paint: @import("../render/PanePaint.zig"),

/// Example: `try terminal_pane.draw(canvas);`
pub fn draw(widget: TerminalPane, canvas: *Canvas) !void {
    try canvas.terminal(widget.paint);
}
