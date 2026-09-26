//! The raised surface of chrome that floats above the panes: a soft shadow,
//! an opaque rounded fill and a hairline. Tooltips and bar panels share it.
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Canvas = @import("Canvas.zig");

const shadow_layers = 3;
const shadow_spread: f32 = 3;
const shadow_offset: f32 = 2;
const shadow_alpha: f32 = 0.08;

/// Example: `try popover_surface.draw(canvas, bounds, canvas.chrome.px(8));`
pub fn draw(canvas: *Canvas, bounds: Rect, radius: f32) !void {
    const chrome = canvas.chrome;
    const palette = canvas.theme.palette;
    for (0..shadow_layers) |layer| {
        const spread = chrome.px(shadow_spread) * @as(f32, @floatFromInt(shadow_layers - layer));
        try canvas.quads.pushRounded(.{
            .x = bounds.x - spread,
            .y = bounds.y - spread + chrome.px(shadow_offset),
            .width = bounds.width + 2 * spread,
            .height = bounds.height + 2 * spread,
        }, .{ .fill = .{ .r = 0, .g = 0, .b = 0, .a = shadow_alpha }, .radius = radius + spread });
    }

    try canvas.fillRoundedAt(bounds, .{ .radius = radius, .color = canvas.covering(palette.surface_dim) });
    try canvas.ringAt(bounds, .{ .color = palette.surface1, .width = chrome.px(1), .radius = radius });
}
