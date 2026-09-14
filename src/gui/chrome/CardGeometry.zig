//! Device-pixel geometry of one agent card, derived from the chrome font
//! metrics so the three rows keep the terminal's glyph size.
const std = @import("std");
const Rect = @import("../render/Rect.zig");
const Metrics = @import("../TerminalMetrics.zig");
const CardGeometry = @This();

pub const padding_x: f32 = 8;
pub const padding_y: f32 = 6;
pub const spacing: f32 = 3;
pub const radius: f32 = 8;
pub const gap: f32 = 6;
pub const mark_size: f32 = 16;
pub const rows = 3;

/// One text row: the glyph height plus a quarter for leading.
row_height: f32,
glyph_width: f32,

/// Example: `const geometry = CardGeometry.derive(canvas.metrics);`
pub fn derive(metrics: Metrics) CardGeometry {
    const glyph: f32 = @floatFromInt(metrics.pixel_height);
    return .{ .row_height = @ceil(glyph * 1.25), .glyph_width = @floatFromInt(metrics.cell_width) };
}

/// Height of a card: three rows inside the vertical padding.
/// Example: `const height = geometry.height();`
pub fn height(geometry: CardGeometry) f32 {
    return rows * geometry.row_height + 2 * padding_y;
}

/// Distance between the tops of two consecutive cards.
/// Example: `const top = list_top + index * geometry.pitch();`
pub fn pitch(geometry: CardGeometry) f32 {
    return geometry.height() + spacing;
}

/// The inner rectangle of row `index` inside a card's outer bounds.
/// Example: `const title_row = geometry.row(card, 1);`
pub fn row(geometry: CardGeometry, bounds: Rect, index: u2) Rect {
    return .{
        .x = bounds.x + padding_x,
        .y = bounds.y + padding_y + @as(f32, @floatFromInt(index)) * geometry.row_height,
        .width = @max(0, bounds.width - 2 * padding_x),
        .height = geometry.row_height,
    };
}

test "card height follows the glyph size" {
    const geometry = derive(.{ .cell_width = 10, .cell_height = 24, .baseline = 18, .pixel_height = 16 });
    try std.testing.expectEqual(@as(f32, 20), geometry.row_height);
    try std.testing.expectEqual(@as(f32, 72), geometry.height());
    try std.testing.expectEqual(@as(f32, 75), geometry.pitch());
    const third = geometry.row(.{ .x = 8, .y = 100, .width = 200, .height = 72 }, 2);
    try std.testing.expectEqual(@as(f32, 16), third.x);
    try std.testing.expectEqual(@as(f32, 146), third.y);
    try std.testing.expectEqual(@as(f32, 184), third.width);
}
