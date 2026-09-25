//! Native modal material shared by pixel-based form dialogs.
const Canvas = @import("../Canvas.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Surface = @This();

bounds: Rect,
viewport: Rect,

/// Dims the underlying window lightly, so the terminal stays readable, and
/// paints an opaque rounded surface with a real shadow and a hairline edge.
/// Example: `try surface.draw(canvas);`
pub fn draw(self: Surface, canvas: *Canvas) !void {
    try canvas.quads.pushRect(self.viewport, .{ .r = 0, .g = 0, .b = 0, .a = 0.25 });
    const first = canvas.quads.items().len;
    const radius = canvas.chrome.px(12);
    for (0..3) |layer| {
        const spread = canvas.chrome.px(@as(f32, @floatFromInt(3 - layer)) * 4);
        try canvas.quads.pushRounded(.{ .x = self.bounds.x - spread, .y = self.bounds.y - spread + canvas.chrome.px(5), .width = self.bounds.width + spread * 2, .height = self.bounds.height + spread * 2 }, .{ .fill = .{ .r = 0, .g = 0, .b = 0, .a = 0.07 }, .radius = radius + spread });
    }

    try canvas.fillRoundedAt(self.bounds, .{ .color = canvas.covering(canvas.theme.palette.panel_bg), .radius = radius });
    try canvas.ringAt(self.bounds, .{ .color = canvas.theme.palette.text, .width = canvas.chrome.px(1), .radius = radius, .alpha = 0.09 });
    canvas.quads.clipFrom(first, self.viewport);
}
