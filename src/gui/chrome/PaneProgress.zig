const core = @import("telar-core");
const std = @import("std");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const colors = @import("../render/cell_colors.zig");
const Color = @import("../render/Color.zig");
const Progress = @This();

context: *Context,
pane: *const client.Pane,

/// Keeps progress as a thin native stroke rather than covering terminal text.
/// Example: `try progress.paint(border);`
pub fn paint(progress: Progress, area: core.Rect) !void {
    if (area.isEmpty()) {
        return;
    }

    try progress.paintPixels(progress.context.canvas.rect(area));
}

/// The same stroke along the bottom edge of a device-pixel rectangle, so a
/// tab in the pixel strip shows its pane's progress.
/// Example: `try progress.paintPixels(tab_bounds);`
pub fn paintPixels(progress: Progress, area: Rect) !void {
    if (progress.pane.progress_state == .remove or area.width <= 0 or area.height <= 0) {
        return;
    }

    const canvas = progress.context.canvas;
    var bounds = area;
    bounds.y += bounds.height - 2;
    bounds.height = 2;
    const palette = canvas.theme.palette;
    const value = switch (progress.pane.progress_state) {
        .@"error" => palette.red,
        .pause => palette.yellow,
        else => palette.teal,
    };
    if (progress.pane.progress_state == .indeterminate) {
        const step: u8 = if (canvas.animation) |clock| @truncate(clock.step(120 * std.time.ns_per_ms)) else progress.context.projection.sidebar_animation_frame;
        const frame: f32 = @floatFromInt(step);
        const phase = if (frame < 128) frame else 255 - frame;
        const thumb = @min(bounds.width, @as(f32, @floatFromInt(canvas.metrics.cell_width)));
        bounds.x += (bounds.width - thumb) * phase / 127;
        bounds.width = thumb;
    } else {
        const percent: f32 = @floatFromInt(progress.pane.progress_percent orelse 100);
        bounds.width *= percent / 100;
    }

    const rgb = canvas.theme.terminal.foreground;
    const color = colors.withPalette(value, Color.rgb(rgb[0], rgb[1], rgb[2]), &canvas.theme.terminal.palette);
    try canvas.quads.pushRect(bounds, color);
}
