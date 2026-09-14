//! Device-pixel geometry of one agent card: a small context row, a title
//! row and a small event row, each as tall as its text role's line box.
const std = @import("std");
const Rect = @import("../render/Rect.zig");
const Metrics = @import("../TerminalMetrics.zig");
const ChromeMetrics = @import("ChromeMetrics.zig");
const CardGeometry = @This();

pub const padding_x: f32 = 8;
pub const padding_y: f32 = 6;
pub const spacing: f32 = 3;
pub const radius: f32 = 8;
pub const gap: f32 = 6;
pub const mark_size: f32 = 16;
pub const rows = 3;

/// The context and event rows, at the `small` role.
small_row: f32,
/// The title row, at the `title` role.
title_row: f32,
glyph_width: f32,

/// Example: `const geometry = CardGeometry.derive(canvas.chrome, canvas.metrics);`
pub fn derive(chrome: ChromeMetrics, metrics: Metrics) CardGeometry {
    return .{ .small_row = chrome.rowHeight(.small), .title_row = chrome.rowHeight(.title), .glyph_width = @floatFromInt(metrics.cell_width) };
}

/// Height of a card: three rows inside the vertical padding.
/// Example: `const height = geometry.height();`
pub fn height(geometry: CardGeometry) f32 {
    return 2 * geometry.small_row + geometry.title_row + 2 * padding_y;
}

/// Distance between the tops of two consecutive cards.
/// Example: `const top = list_top + index * geometry.pitch();`
pub fn pitch(geometry: CardGeometry) f32 {
    return geometry.height() + spacing;
}

/// The inner rectangle of row `index` inside a card's outer bounds.
/// Example: `const title_row = geometry.row(card, 1);`
pub fn row(geometry: CardGeometry, bounds: Rect, index: u2) Rect {
    const top: f32 = switch (index) {
        0 => 0,
        1 => geometry.small_row,
        else => geometry.small_row + geometry.title_row,
    };
    return .{
        .x = bounds.x + padding_x,
        .y = bounds.y + padding_y + top,
        .width = @max(0, bounds.width - 2 * padding_x),
        .height = if (index == 1) geometry.title_row else geometry.small_row,
    };
}

test "card rows follow the text roles and grow with the chrome scale" {
    const metrics: Metrics = .{ .cell_width = 10, .cell_height = 24, .baseline = 18, .pixel_height = 16 };
    const geometry = derive(ChromeMetrics.resolve(.{}, 1), metrics);
    try std.testing.expectEqual(@as(f32, 15), geometry.small_row);
    try std.testing.expectEqual(@as(f32, 20), geometry.title_row);
    try std.testing.expectEqual(@as(f32, 62), geometry.height());
    try std.testing.expectEqual(@as(f32, 65), geometry.pitch());
    const title = geometry.row(.{ .x = 8, .y = 100, .width = 200, .height = 62 }, 1);
    try std.testing.expectEqual(@as(f32, 121), title.y);
    try std.testing.expectEqual(@as(f32, 20), title.height);
    const third = geometry.row(.{ .x = 8, .y = 100, .width = 200, .height = 62 }, 2);
    try std.testing.expectEqual(@as(f32, 16), third.x);
    try std.testing.expectEqual(@as(f32, 141), third.y);
    try std.testing.expectEqual(@as(f32, 184), third.width);
    const scaled = derive(ChromeMetrics.resolve(.{ .chrome = .{ .scale = 1.5 } }, 1), metrics);
    try std.testing.expect(scaled.height() > geometry.height());
    try std.testing.expectEqual(geometry.glyph_width, scaled.glyph_width);
}
