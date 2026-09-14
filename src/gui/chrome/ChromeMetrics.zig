//! Physical heights of the native chrome bands and the chrome text sizes.
//! The plan fixes the bands in logical pixels at the default terminal size;
//! they scale with the display and with `gui.font.size`, so a larger font
//! gets taller bars, and every band is rounded to whole device pixels
//! before the cell grid is measured. Text sizes derive from the terminal
//! size too, times `gui.chrome.scale`, and never move the bands.
const std = @import("std");
const GuiConfig = @import("telar-client").GuiConfig;
const Size = @import("label_size.zig").Size;
const Metrics = @This();

/// Logical heights at the reference font size, from the visual language plan.
pub const logical_top_bar: f32 = 38;
pub const logical_tab_strip: f32 = 32;
pub const logical_status_bar: f32 = 26;
pub const logical_pane_header: f32 = 22;
/// The terminal size the logical heights were designed against.
pub const reference_font_size: f32 = 15;
/// Chrome text roles relative to the terminal size.
pub const title_ratio: f32 = 1.0;
pub const body_ratio: f32 = 0.87;
pub const small_ratio: f32 = 0.73;
/// IBM Plex Sans line box per em: hhea ascender 1025 plus descender 275
/// over 1000 units. Rows and the band cap are derived from it.
pub const sans_line_ratio: f32 = 1.3;
/// No chrome text is rounded below this many device pixels.
pub const min_text_px: u16 = 6;

top_bar: u32 = 0,
tab_strip: u32 = 0,
status_bar: u32 = 0,
pane_header: u32 = 0,
/// Device pixels per logical chrome pixel, for insets and dots.
ratio: f32 = 1,
/// Chrome text sizes in device pixels; `body` is capped so its line box
/// fits the pane header, the shortest band that shows it.
title: u16 = 0,
body: u16 = 0,
small: u16 = 0,

/// Resolves every band and text size for one display scale and configuration.
/// Example: `const chrome = ChromeMetrics.resolve(renderer.config, viewport.scale);`
pub fn resolve(config: GuiConfig, scale: f32) Metrics {
    const font = config.font;
    const ratio = scale * font.size / reference_font_size;
    const base = font.size * scale * config.chrome.scale;
    const pane_header = physical(logical_pane_header, ratio);
    return .{
        .top_bar = physical(logical_top_bar, ratio),
        .tab_strip = physical(logical_tab_strip, ratio),
        .status_bar = physical(logical_status_bar, ratio),
        .pane_header = pane_header,
        .ratio = if (std.math.isFinite(ratio) and ratio > 0) ratio else 1,
        .title = textSize(base * title_ratio),
        .body = @min(textSize(base * body_ratio), bandText(pane_header)),
        .small = textSize(base * small_ratio),
    };
}

/// Scales one logical chrome length to device pixels without rounding.
/// Example: `const inset = canvas.chrome.px(8);`
pub fn px(metrics: Metrics, logical: f32) f32 {
    return logical * metrics.ratio;
}

/// The pixel height of one text role; the terminal role is the caller's.
/// Example: `const height = canvas.chrome.textSize(.small) orelse canvas.metrics.pixel_height;`
pub fn text(metrics: Metrics, size: Size) ?u16 {
    return switch (size) {
        .terminal => null,
        .title => metrics.title,
        .body => metrics.body,
        .small => metrics.small,
    };
}

/// The row one sans label of `size` needs: its line box rounded up.
/// Example: `const header_height = canvas.chrome.rowHeight(.body);`
pub fn rowHeight(metrics: Metrics, size: Size) f32 {
    const pixels: f32 = @floatFromInt(metrics.text(size) orelse 0);
    return @ceil(pixels * sans_line_ratio);
}

/// Gives a tiny window back to the terminal: drops the status bar, then the
/// tab strip, then the top bar until one cell row fits, the way the cell
/// regions kept a terminal row in a one-row host.
/// Example: `const chrome = ChromeMetrics.resolve(config, scale).fit(viewport.height, cell_height);`
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

fn textSize(pixels: f32) u16 {
    const value = @round(pixels);
    if (!(value >= min_text_px)) {
        return min_text_px;
    }

    return @intFromFloat(@min(value, 4096));
}

// The largest em whose Plex line box fits inside a band of `height` pixels.
fn bandText(height: u32) u16 {
    const em = @floor(@as(f32, @floatFromInt(height)) / sans_line_ratio);
    return textSize(em);
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
    const large = Metrics.resolve(.{ .font = .{ .size = 30 } }, 1);
    try std.testing.expectEqual(@as(u32, 76), large.top_bar);
    try std.testing.expectEqual(@as(u32, 44), large.pane_header);
    const odd = Metrics.resolve(.{ .font = .{ .size = 13 } }, 1.5);
    try std.testing.expectEqual(@as(u32, 49), odd.top_bar);
    try std.testing.expectEqual(@as(u32, 0), Metrics.resolve(.{ .font = .{ .size = 0 } }, 1).top_bar);
    const tiny = base.fit(120, 30);
    try std.testing.expectEqual(@as(u32, 0), tiny.status_bar);
    try std.testing.expectEqual(@as(u32, 32), tiny.tab_strip);
    const one_row = base.fit(60, 30);
    try std.testing.expectEqual(@as(u32, 0), one_row.vertical());
    try std.testing.expectEqual(@as(u32, 96), base.fit(126, 30).vertical());
}

test "chrome text sizes follow the terminal size and the chrome scale but never the bands" {
    const base = Metrics.resolve(.{}, 1);
    try std.testing.expectEqual(@as(u16, 15), base.title);
    try std.testing.expectEqual(@as(u16, 13), base.body);
    try std.testing.expectEqual(@as(u16, 11), base.small);
    try std.testing.expectEqual(@as(f32, 20), base.rowHeight(.title));
    try std.testing.expectEqual(@as(f32, 15), base.rowHeight(.small));
    try std.testing.expectEqual(@as(?u16, null), base.text(.terminal));
    const retina = Metrics.resolve(.{}, 2);
    try std.testing.expectEqual(@as(u16, 30), retina.title);
    try std.testing.expectEqual(@as(u16, 26), retina.body);
    try std.testing.expectEqual(@as(u16, 22), retina.small);

    const larger = Metrics.resolve(.{ .chrome = .{ .scale = 1.5 } }, 1);
    try std.testing.expectEqual(base.top_bar, larger.top_bar);
    try std.testing.expectEqual(base.pane_header, larger.pane_header);
    try std.testing.expectEqual(@as(u16, 23), larger.title);
    try std.testing.expectEqual(@as(u16, 16), larger.body);
    try std.testing.expectEqual(@as(u16, 16), larger.small);
    try std.testing.expect(larger.body * sans_line_ratio <= @as(f32, @floatFromInt(larger.pane_header)));

    // At scale 2 the title and small roles double; the body stays at the
    // largest size whose line box fits the 22 px pane header.
    const doubled = Metrics.resolve(.{ .chrome = .{ .scale = 2 } }, 1);
    try std.testing.expectEqual(@as(u16, 30), doubled.title);
    try std.testing.expectEqual(@as(u16, 16), doubled.body);
    try std.testing.expectEqual(@as(u16, 22), doubled.small);
    const smallest = Metrics.resolve(.{ .font = .{ .size = 6 }, .chrome = .{ .scale = 0.5 } }, 1);
    try std.testing.expectEqual(@as(u16, 6), smallest.small);
    try std.testing.expectEqual(@as(u16, 6), smallest.title);
    try std.testing.expectEqual(@as(u16, min_text_px), Metrics.resolve(.{ .font = .{ .size = 0 } }, 1).body);
}
