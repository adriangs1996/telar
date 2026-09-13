//! Native chrome drawing over the terminal atlas and the host's measured grid.
//! Every primitive is clipped to its supplied area; no widget owns GPU resources.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Color = @import("../render/Color.zig");
const Rect = @import("../render/Rect.zig");
const colors = @import("../render/cell_colors.zig");
const Label = @import("Label.zig");
const Canvas = @This();

atlas: *@import("../text/GlyphAtlas.zig"),
quads: *@import("../render/QuadList.zig"),
metrics: @import("../TerminalMetrics.zig"),
origin: [2]u32,
theme: client.ColorTheme,

/// Converts host grid coordinates including the configured window inset.
/// Example: `const pixels = canvas.rect(regions.top);`
pub fn rect(canvas: Canvas, area: core.Rect) Rect {
    return canvas.metrics.rect(canvas.origin, area);
}

/// Paints a native rectangle, including backgrounds beneath labels.
/// Example: `try canvas.fill(regions.sidebar, canvas.theme.palette.panel_bg);`
pub fn fill(canvas: *Canvas, area: core.Rect, ink_color: core.Color) !void {
    if (area.isEmpty()) {
        return;
    }

    try canvas.quads.pushRect(canvas.rect(area), canvas.color(ink_color, canvas.theme.terminal.background));
}

/// Uses the shared grapheme widths for clipping, hit targets and letter spacing.
/// Cached glyphs bypass shaping and rasterization after warmup.
/// Example: `try canvas.text(area, .{ .text = "Workspace", .bold = true });`
pub fn text(canvas: *Canvas, area: core.Rect, label: Label) !void {
    if (area.isEmpty()) {
        return;
    }

    const first = canvas.quads.items().len;
    const bounds = canvas.rect(area.row(0));
    var ink = canvas.color(label.color, canvas.theme.terminal.foreground);
    if (label.faint) {
        ink.a *= 0.5;
    }
    var iterator: core.GraphemeIterator = .{ .bytes = label.text };
    var column: u16 = 0;
    while (column < area.w) {
        const cluster = iterator.next() orelse break;
        if (cluster.width > area.w - column) {
            break;
        }

        _ = try canvas.atlas.place(.{
            .text = cluster.bytes,
            .x = bounds.x + @as(f32, @floatFromInt(@as(u32, column) * canvas.metrics.cell_width)),
            .y = bounds.y + canvas.metrics.baseline,
            .pixel_height = canvas.metrics.pixel_height,
            .cell_bounds = canvas.metrics.glyphCell(),
            .color = ink,
            .bold = label.bold,
            .italic = label.italic,
        }, canvas.quads);
        column += cluster.width;
    }

    const width: f32 = @floatFromInt(@as(u32, column) * canvas.metrics.cell_width);
    if (label.underline and width != 0) {
        try canvas.quads.pushRect(.{ .x = bounds.x, .y = bounds.y + bounds.height - 2, .width = width, .height = 1 }, ink);
    }

    if (label.strikethrough and width != 0) {
        try canvas.quads.pushRect(.{ .x = bounds.x, .y = bounds.y + bounds.height * 0.5, .width = width, .height = 1 }, ink);
    }

    canvas.quads.clipFrom(first, bounds);
}

/// Outlines a region with pixel strokes rather than terminal border glyphs.
/// Example: `try canvas.border(pane.outer, canvas.theme.palette.accent);`
pub fn border(canvas: *Canvas, area: core.Rect, ink_color: core.Color) !void {
    if (area.isEmpty()) {
        return;
    }

    const bounds = canvas.rect(area);
    const ink = canvas.color(ink_color, canvas.theme.terminal.foreground);
    try canvas.quads.pushRect(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = 1 }, ink);
    try canvas.quads.pushRect(.{ .x = bounds.x, .y = bounds.y + bounds.height - 1, .width = bounds.width, .height = 1 }, ink);
    try canvas.quads.pushRect(.{ .x = bounds.x, .y = bounds.y, .width = 1, .height = bounds.height }, ink);
    try canvas.quads.pushRect(.{ .x = bounds.x + bounds.width - 1, .y = bounds.y, .width = 1, .height = bounds.height }, ink);
}

fn color(canvas: Canvas, value: core.Color, fallback: [3]u8) Color {
    return colors.withPalette(value, Color.rgb(fallback[0], fallback[1], fallback[2]), &canvas.theme.terminal.palette);
}

test "chrome text clips graphemes preserves metrics and reuses the terminal atlas" {
    var atlas = try @import("../text/GlyphAtlas.zig").init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var quads = @import("../render/QuadList.zig").init(std.testing.allocator);
    defer quads.deinit();
    var canvas: Canvas = .{
        .atlas = &atlas,
        .quads = &quads,
        .origin = .{ 8, 12 },
        .metrics = .{ .cell_width = 12, .cell_height = 24, .baseline = 18, .pixel_height = 16 },
        .theme = client.theme_support.default_theme,
    };
    const area: core.Rect = .{ .x = 2, .y = 3, .w = 3, .h = 1 };
    const label: Label = .{ .text = "e\u{301}界hidden", .underline = true };
    try canvas.text(area, label);
    const bounds = canvas.rect(area);
    try std.testing.expect(quads.items().len > 0);
    for (quads.items()) |quad| {
        try std.testing.expect(quad.x >= bounds.x and quad.y >= bounds.y);
        try std.testing.expect(quad.x + quad.width <= bounds.x + bounds.width);
        try std.testing.expect(quad.y + quad.height <= bounds.y + bounds.height);
    }

    const version = atlas.version;
    const calls = atlas.shape_calls;
    quads.clear();
    try canvas.text(area, label);
    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expectEqual(calls, atlas.shape_calls);
}

test "fallback icons fit each chrome column with negative letter spacing" {
    var renderer = @import("../render/TerminalRenderer.zig").init(std.testing.allocator);
    defer renderer.deinit();
    renderer.config.font = .{ .size = 22, .line_height = 0.75, .letter_spacing = -5, .thicken = true };
    _ = try renderer.measure(.{ .width = 800, .height = 600, .scale = 2 });
    var quads = @import("../render/QuadList.zig").init(std.testing.allocator);
    defer quads.deinit();
    var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &quads, .metrics = renderer.metrics, .origin = .{ 8, 12 }, .theme = client.theme_support.default_theme };
    const area: core.Rect = .{ .x = 1, .y = 1, .w = 3, .h = 1 };
    try canvas.text(area, .{ .text = "\u{f07b}\u{f02db} " });
    try std.testing.expectEqual(@as(usize, 2), quads.items().len);
    const bounds = canvas.rect(area);
    const width: f32 = @floatFromInt(renderer.metrics.cell_width);
    for (quads.items(), 0..) |item, index| {
        const x = bounds.x + @as(f32, @floatFromInt(index)) * width;
        try std.testing.expect(item.x >= x and item.x + item.width <= x + width + 0.001);
        try std.testing.expect(item.y >= bounds.y and item.y + item.height <= bounds.y + bounds.height + 0.001);
    }
}
