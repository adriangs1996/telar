//! A tab's neutral outline and rounded upper corners. Its open lower edge
//! joins the terminal background without a separate selection stripe.
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Surface = @import("../widgets/Surface.zig");
const TabSurface = @This();

bounds: Rect,
active: bool,
hovered: bool,

/// Example: `try (TabSurface{ .bounds = bounds, .active = active, .hovered = hovered }).draw(canvas);`
pub fn draw(surface: TabSurface, canvas: *Canvas) !void {
    const bounds = surface.bounds;
    if (bounds.width <= 0 or bounds.height <= 0) {
        return;
    }

    const border = @min(canvas.chrome.px(1), @min(bounds.width / 2, bounds.height));
    try shape(canvas, bounds, canvas.theme.palette.surface1);
    const inner: Rect = .{
        .x = bounds.x + border,
        .y = bounds.y + border,
        .width = @max(0, bounds.width - 2 * border),
        .height = @max(0, bounds.height - border - (if (surface.active) @as(f32, 0) else border)),
    };
    const color = if (surface.active) canvas.covering(.default) else if (surface.hovered) canvas.theme.palette.surface1 else canvas.theme.palette.surface0;
    try shape(canvas, inner, color);
}

fn shape(canvas: *Canvas, bounds: Rect, color: core.Color) !void {
    const radius = @min(canvas.chrome.px(8), @min(bounds.width, bounds.height) / 2);
    const head: Surface = .{ .bounds = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = radius * 2 }, .fill = .{ .radius = radius, .color = color } };
    try head.draw(canvas);
    try canvas.fillAt(.{ .x = bounds.x, .y = bounds.y + radius, .width = bounds.width, .height = @max(0, bounds.height - radius) }, color);
}
