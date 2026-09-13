//! Fits fallback ink to the configured grid while preserving its aspect ratio.
const std = @import("std");
const Rect = @import("../render/Rect.zig");
const Transform = @This();

x: f32 = 0,
y: f32 = 0,
scale: f32 = 1,

/// Bounds use coordinates relative to the pen baseline; covered primary text bypasses this.
/// Example: `const transform = GlyphTransform.fit(ink_bounds, cell_bounds);`
pub fn fit(ink: Rect, cell: Rect) Transform {
    if (!std.math.isFinite(ink.width) or ink.width <= 0 or ink.height <= 0) {
        return .{};
    }

    const scale = @min(1, @min(cell.width / ink.width, cell.height / ink.height));
    const top = ink.y * scale;
    const bottom = top + ink.height * scale;
    return .{
        .scale = scale,
        .x = cell.x + (cell.width - ink.width * scale) / 2 - ink.x * scale,
        .y = if (top < cell.y) cell.y - top else if (bottom > cell.y + cell.height) cell.y + cell.height - bottom else 0,
    };
}
