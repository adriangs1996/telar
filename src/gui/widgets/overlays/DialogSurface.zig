//! Native modal material shared by pixel-based form dialogs.
const Canvas = @import("../Canvas.zig");
const Rect = @import("../../render/Rect.zig");
const Surface = @This();

bounds: Rect,
viewport: Rect,

/// Dims the underlying window and paints an opaque, rounded dialog surface.
/// Example: `try surface.draw(canvas);`
pub fn draw(surface: Surface, canvas: *Canvas) !void {
    try canvas.quads.pushRect(surface.viewport, .{ .r = 0, .g = 0, .b = 0, .a = 0.32 });
    const first = canvas.quads.items().len;
    const radius = canvas.chrome.px(14);
    for (0..3) |layer| {
        const spread = canvas.chrome.px(@as(f32, @floatFromInt(3 - layer)) * 4);
        try canvas.quads.pushRounded(.{ .x = surface.bounds.x - spread, .y = surface.bounds.y - spread + canvas.chrome.px(5), .width = surface.bounds.width + spread * 2, .height = surface.bounds.height + spread * 2 }, .{ .fill = .{ .r = 0, .g = 0, .b = 0, .a = 0.07 }, .radius = radius + spread });
    }

    try canvas.fillRoundedAt(surface.bounds, .{ .color = canvas.covering(canvas.theme.palette.panel_bg), .radius = radius });
    try canvas.ringAt(surface.bounds, .{ .color = canvas.theme.palette.overlay0, .width = canvas.chrome.px(1), .radius = radius, .alpha = 0.45 });
    canvas.quads.clipFrom(first, surface.viewport);
}
