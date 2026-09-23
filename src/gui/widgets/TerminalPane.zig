//! One visible terminal leaf, borrowed only until its synchronous draw ends.
const Canvas = @import("Canvas.zig");
const PanePaint = @import("../render/PanePaint.zig");
const TerminalPane = @This();

paint: PanePaint,

/// Example: `try terminal_pane.draw(canvas);`
pub fn draw(self: TerminalPane, canvas: *Canvas) !void {
    try canvas.terminal(self.paint);
}
