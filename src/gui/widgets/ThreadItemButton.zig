//! A generation-scoped conversation control clipped to the visible transcript.
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Button = @This();

bounds: Rect,
viewport: Rect,
control: @import("interaction/ThreadItemControl.zig"),
label: []const u8,

/// Publishes the visible part of one toggle or copy action.
/// Example: `try button.register(canvas);`
pub fn register(self: Button, canvas: *Canvas) !void {
    const state = canvas.widgets orelse return;
    if (self.control.identity == 0) {
        return;
    }

    const left = @max(self.bounds.x, self.viewport.x);
    const top = @max(self.bounds.y, self.viewport.y);
    const right = @min(self.bounds.x + self.bounds.width, self.viewport.x + self.viewport.width);
    const bottom = @min(self.bounds.y + self.bounds.height, self.viewport.y + self.viewport.height);
    if (right <= left or bottom <= top) {
        return;
    }

    _ = try state.dispatcher.add((@import("interaction/Target.zig"){ .id = .{ .generation = self.control.attachment_generation }, .bounds = .{ .x = left, .y = top, .width = right - left, .height = bottom - top }, .action = .{ .thread_item = self.control }, .thread_header_offset = self.bounds.y - self.viewport.y }).labelled(self.label));
}
