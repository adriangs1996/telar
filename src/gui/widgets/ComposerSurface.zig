const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Surface = @This();

bounds: Rect,
radius: f32,
focused: bool = false,

/// A restrained elevated surface shared by the card and its popover.
/// Example: `try surface.draw(canvas);`
pub fn draw(self: Surface, canvas: *Canvas) !void {
    if (self.bounds.width <= 0 or self.bounds.height <= 0) {
        return;
    }

    for ([_]f32{ 7, 3 }) |spread| {
        const size = canvas.chrome.px(spread);
        const bounds: Rect = .{ .x = self.bounds.x - size, .y = self.bounds.y - size + canvas.chrome.px(3), .width = self.bounds.width + 2 * size, .height = self.bounds.height + 2 * size };
        try canvas.quads.pushRounded(bounds, .{ .fill = .{ .r = 0, .g = 0, .b = 0, .a = 0.055 }, .radius = self.radius + size });
    }

    try canvas.fillRoundedAt(self.bounds, .{ .color = canvas.covering(canvas.theme.palette.surface0), .radius = self.radius });
    try canvas.ringAt(self.bounds, .{ .color = if (self.focused) canvas.theme.palette.accent else canvas.theme.palette.overlay0, .radius = self.radius, .width = canvas.chrome.px(0.7), .alpha = if (self.focused) 0.35 else 0.55 });
}
