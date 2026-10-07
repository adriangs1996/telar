//! Final registration follows modal drawing, so targets use this frame's bounds.
const Canvas = @import("Canvas.zig");
const Overlays = @import("overlays/Overlays.zig");
const InteractionTargets = @This();

overlays: *Overlays,

pub fn draw(self: InteractionTargets, canvas: *Canvas) !void {
    const state = canvas.widgets orelse return;
    try state.overlays(canvas, self.overlays);
    try state.copy_feedback.draw(canvas);
}
