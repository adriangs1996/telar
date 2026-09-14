//! Physical heights of the native chrome bands. The plan fixes them in
//! logical pixels at the default terminal size; they scale with the display
//! and with `gui.font.size`, so a larger font gets taller bars, and every
//! band is rounded to whole device pixels before the cell grid is measured.
const std = @import("std");
const GuiFont = @import("telar-client").GuiFont;
const Metrics = @This();

/// Logical heights at the reference font size, from the visual language plan.
pub const logical_top_bar: f32 = 38;
pub const logical_tab_strip: f32 = 32;
pub const logical_status_bar: f32 = 26;
pub const logical_pane_header: f32 = 22;
/// The terminal size the logical heights were designed against.
pub const reference_font_size: f32 = 15;

top_bar: u32 = 0,
tab_strip: u32 = 0,
status_bar: u32 = 0,
pane_header: u32 = 0,
/// Device pixels per logical chrome pixel, for insets and dots.
ratio: f32 = 1,

/// Resolves every band for one display scale and configured font.
/// Example: `const chrome = ChromeMetrics.resolve(config.font, viewport.scale);`
pub fn resolve(font: GuiFont, scale: f32) Metrics {
    const ratio = scale * font.size / reference_font_size;
    return .{
        .top_bar = physical(logical_top_bar, ratio),
        .tab_strip = physical(logical_tab_strip, ratio),
        .status_bar = physical(logical_status_bar, ratio),
        .pane_header = physical(logical_pane_header, ratio),
        .ratio = if (std.math.isFinite(ratio) and ratio > 0) ratio else 1,
    };
}

/// Scales one logical chrome length to device pixels without rounding.
/// Example: `const inset = canvas.chrome.px(8);`
pub fn px(metrics: Metrics, logical: f32) f32 {
    return logical * metrics.ratio;
}

/// Gives a tiny window back to the terminal: drops the status bar, then the
/// tab strip, then the top bar until one cell row fits, the way the cell
/// regions kept a terminal row in a one-row host.
/// Example: `const chrome = ChromeMetrics.resolve(font, scale).fit(viewport.height, cell_height);`
pub fn fit(metrics: Metrics, height: u32, cell_height: u32) Metrics {
    var fitted = metrics;
    if (height -| fitted.vertical() < cell_height) {
        fitted.status_bar = 0;
    }

    if (height -| fitted.vertical() < cell_height) {
        fitted.tab_strip = 0;
    }

    if (height -| fitted.vertical() < cell_height) {
        fitted.top_bar = 0;
    }

    return fitted;
}

/// Pixels reserved above and below the cell grid.
/// Example: `const rows = (height -| chrome.vertical()) / cell_height;`
pub fn vertical(metrics: Metrics) u32 {
    return metrics.top_bar + metrics.tab_strip + metrics.status_bar;
}

fn physical(logical: f32, ratio: f32) u32 {
    const value = @round(logical * ratio);
    if (!(value >= 0) or value > 4096) {
        return 0;
    }

    return @intFromFloat(value);
}

test "chrome bands scale with display and font size and round to device pixels" {
    const base = Metrics.resolve(.{}, 1);
    try std.testing.expectEqual(@as(u32, 38), base.top_bar);
    try std.testing.expectEqual(@as(u32, 32), base.tab_strip);
    try std.testing.expectEqual(@as(u32, 26), base.status_bar);
    try std.testing.expectEqual(@as(u32, 22), base.pane_header);
    try std.testing.expectEqual(@as(u32, 96), base.vertical());
    const retina = Metrics.resolve(.{}, 2);
    try std.testing.expectEqual(@as(u32, 76), retina.top_bar);
    const large = Metrics.resolve(.{ .size = 30 }, 1);
    try std.testing.expectEqual(@as(u32, 76), large.top_bar);
    try std.testing.expectEqual(@as(u32, 44), large.pane_header);
    const odd = Metrics.resolve(.{ .size = 13 }, 1.5);
    try std.testing.expectEqual(@as(u32, 49), odd.top_bar);
    try std.testing.expectEqual(@as(u32, 0), Metrics.resolve(.{ .size = 0 }, 1).top_bar);
    const tiny = base.fit(120, 30);
    try std.testing.expectEqual(@as(u32, 0), tiny.status_bar);
    try std.testing.expectEqual(@as(u32, 32), tiny.tab_strip);
    const one_row = base.fit(60, 30);
    try std.testing.expectEqual(@as(u32, 0), one_row.vertical());
    try std.testing.expectEqual(@as(u32, 96), base.fit(126, 30).vertical());
}
