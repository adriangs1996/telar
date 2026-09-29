//! Device-pixel geometry of one agent card: a small context row, a regular title
//! row and a small event row, each as tall as its text role's line box.
const std = @import("std");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Metrics = @import("../TerminalMetrics.zig");
const ChromeMetrics = @import("ChromeMetrics.zig");
const SpriteSize = @import("../image/SpriteSize.zig").SpriteSize;
const client = @import("telar-client");
const FleetCard = client.FleetCard;
const CardGeometry = @This();

pub const padding_x: f32 = 10;
pub const padding_y: f32 = 8;
pub const spacing: f32 = 3;
pub const radius: f32 = 8;
pub const gap: f32 = 6;
/// The provider mark and the project favicon: the favicon's `small` cell.
pub const mark_size: f32 = SpriteSize.small.logical();
pub const compact_padding_y: f32 = 4;
/// Indent of a task under its project's own agents.
pub const task_indent: f32 = 12;
/// Extra space before each project group after the first.
pub const group_gap: f32 = 8;

/// The context and event rows, at the `small` role.
small_row: f32,
/// The regular title uses body-sized text without the header's height cap.
title_row: f32,
glyph_width: f32,
scale: f32,

/// Example: `const geometry = CardGeometry.derive(canvas.chrome, canvas.metrics);`
pub fn derive(chrome: ChromeMetrics, metrics: Metrics) CardGeometry {
    return .{ .small_row = chrome.rowHeight(.small), .title_row = chrome.rowHeight(.title), .glyph_width = @floatFromInt(metrics.cell_width), .scale = chrome.ratio };
}

/// Scales card spacing with the same display and font ratio as its icons.
/// Example: `const inset = geometry.px(CardGeometry.padding_x);`
pub fn px(self: CardGeometry, logical: f32) f32 {
    return @round(logical * self.scale);
}

/// Height of a card: three rows inside the vertical padding.
/// Example: `const height = geometry.height();`
pub fn height(self: CardGeometry) f32 {
    return 2 * self.small_row + self.title_row + self.px(6) + 2 * self.px(padding_y);
}

/// Height of a one-line task: a body row inside a slimmer padding.
/// Example: `const height = geometry.compactHeight();`
pub fn compactHeight(self: CardGeometry) f32 {
    return self.title_row + 2 * self.px(compact_padding_y);
}

/// Height of one fleet entry as the sidebar draws it.
/// Example: `const height = geometry.entryHeight(.task_compact);`
pub fn entryHeight(self: CardGeometry, card: FleetCard) f32 {
    return switch (card) {
        .agent, .task_full => self.height(),
        .task_compact => self.compactHeight(),
    };
}

/// Distance between the tops of two consecutive cards.
/// Example: `const top = list_top + index * geometry.pitch();`
pub fn pitch(self: CardGeometry) f32 {
    return self.height() + self.px(spacing);
}

/// The inner rectangle of row `index` inside a card's outer bounds.
/// Example: `const title_row = geometry.row(card, 1);`
pub fn row(self: CardGeometry, bounds: Rect, index: u2) Rect {
    const top: f32 = switch (index) {
        0 => 0,
        1 => self.small_row + self.px(4),
        else => self.small_row + self.title_row + self.px(6),
    };
    return .{
        .x = bounds.x + self.px(padding_x),
        .y = bounds.y + self.px(padding_y) + top,
        .width = @max(0, bounds.width - 2 * self.px(padding_x)),
        .height = if (index == 1) self.title_row else self.small_row,
    };
}

test "card rows follow the text roles and grow with the chrome scale" {
    const metrics: Metrics = .{ .cell_width = 10, .cell_height = 24, .baseline = 18, .pixel_height = 16 };
    const geometry = derive(ChromeMetrics.resolve(.{}, 1), metrics);
    try std.testing.expectEqual(@as(f32, 15), geometry.small_row);
    try std.testing.expectEqual(@as(f32, 17), geometry.title_row);
    try std.testing.expectEqual(@as(f32, 69), geometry.height());
    try std.testing.expectEqual(@as(f32, 72), geometry.pitch());
    const title = geometry.row(.{ .x = 8, .y = 100, .width = 200, .height = 62 }, 1);
    try std.testing.expectEqual(@as(f32, 127), title.y);
    try std.testing.expectEqual(@as(f32, 17), title.height);
    const third = geometry.row(.{ .x = 8, .y = 100, .width = 200, .height = 62 }, 2);
    try std.testing.expectEqual(@as(f32, 18), third.x);
    try std.testing.expectEqual(@as(f32, 146), third.y);
    try std.testing.expectEqual(@as(f32, 180), third.width);
    const scaled = derive(ChromeMetrics.resolve(.{ .chrome = .{ .scale = 1.5 } }, 1), metrics);
    try std.testing.expect(scaled.height() > geometry.height());
    try std.testing.expectEqual(geometry.glyph_width, scaled.glyph_width);
    const retina = derive(ChromeMetrics.resolve(.{}, 2), metrics);
    try std.testing.expectEqual(2 * geometry.px(padding_x), retina.px(padding_x));
    try std.testing.expectEqual(2 * geometry.px(padding_y), retina.px(padding_y));
    try std.testing.expectEqual(2 * geometry.px(radius), retina.px(radius));
    const enlarged = derive(ChromeMetrics.resolve(.{ .chrome = .{ .scale = 2 } }, 1), metrics);
    try std.testing.expect(enlarged.title_row > enlarged.small_row);
}
