const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Surface = @This();

bounds: Rect,
radius: f32,
focused: bool = false,

/// A restrained elevated surface shared by the card and its popover.
/// Example: `try surface.draw(canvas);`
pub fn draw(surface: Surface, canvas: *Canvas) !void {
    if (surface.bounds.width <= 0 or surface.bounds.height <= 0) {
        return;
    }

    for ([_]f32{ 7, 3 }) |spread| {
        const size = canvas.chrome.px(spread);
        const bounds: Rect = .{ .x = surface.bounds.x - size, .y = surface.bounds.y - size + canvas.chrome.px(3), .width = surface.bounds.width + 2 * size, .height = surface.bounds.height + 2 * size };
        try canvas.quads.pushRounded(bounds, .{ .fill = .{ .r = 0, .g = 0, .b = 0, .a = 0.055 }, .radius = surface.radius + size });
    }

    try canvas.fillRoundedAt(surface.bounds, .{ .color = canvas.covering(canvas.theme.palette.surface0), .radius = surface.radius });
    try canvas.ringAt(surface.bounds, .{ .color = if (surface.focused) canvas.theme.palette.accent else canvas.theme.palette.overlay0, .radius = surface.radius, .width = canvas.chrome.px(0.7), .alpha = if (surface.focused) 0.35 else 0.55 });
}
