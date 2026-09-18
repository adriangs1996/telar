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
pub fn register(button: Button, canvas: *Canvas) !void {
    const state = canvas.widgets orelse return;
    if (button.control.identity == 0) {
        return;
    }

    const left = @max(button.bounds.x, button.viewport.x);
    const top = @max(button.bounds.y, button.viewport.y);
    const right = @min(button.bounds.x + button.bounds.width, button.viewport.x + button.viewport.width);
    const bottom = @min(button.bounds.y + button.bounds.height, button.viewport.y + button.viewport.height);
    if (right <= left or bottom <= top) {
        return;
    }

    _ = try state.dispatcher.add((@import("interaction/Target.zig"){ .id = .{ .generation = button.control.attachment_generation }, .bounds = .{ .x = left, .y = top, .width = right - left, .height = bottom - top }, .action = .{ .thread_item = button.control }, .thread_header_offset = button.bounds.y - button.viewport.y }).labelled(button.label));
}
