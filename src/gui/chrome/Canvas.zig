//! Native chrome drawing over the terminal atlas and the host's measured grid.
//! Every primitive is clipped to its supplied area; no widget owns GPU resources.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Color = @import("../render/Color.zig");
const Rect = @import("../render/Rect.zig");
const colors = @import("../render/cell_colors.zig");
const Label = @import("Label.zig");
const RoundedFill = @import("RoundedFill.zig");
const Ring = @import("Ring.zig");
const TextRun = @import("../text/TextRun.zig");
const LineBox = @import("../text/LineBox.zig");
const ChromeMetrics = @import("ChromeMetrics.zig");
const LabelPlacement = @import("LabelPlacement.zig");
const SpritePage = @import("../image/SpritePage.zig");
const Sprite = @import("../image/Sprite.zig");
const Canvas = @This();

atlas: *@import("../text/GlyphAtlas.zig"),
quads: *@import("../render/QuadList.zig"),
metrics: @import("../TerminalMetrics.zig"),
origin: [2]u32,
theme: client.ColorTheme,
/// Band heights already subtracted from the grid by the renderer.
chrome: ChromeMetrics = .{},
/// Whole window in device pixels; the bands span it, the grid sits inside.
viewport: [2]u32 = .{ 0, 0 },
/// The RGBA sprite page of the renderer; `null` while a fixture has none,
/// in which case `spriteAt` draws nothing and `providerMark` finds nothing.
sprites: ?*const SpritePage = null,

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

    try canvas.fillAt(canvas.rect(area), ink_color);
}

/// `fill` over a device-pixel rectangle, for chrome laid out in pixels.
/// Example: `try canvas.fillAt(thumb, palette.overlay0);`
pub fn fillAt(canvas: *Canvas, bounds: Rect, ink_color: core.Color) !void {
    if (bounds.width <= 0 or bounds.height <= 0) {
        return;
    }

    try canvas.quads.pushRect(bounds, canvas.color(ink_color, canvas.theme.terminal.background));
}

/// Paints a rounded surface; the fragment shader resolves the corners, so it
/// costs one quad like `fill`. Radius is in device pixels.
/// Example: `try canvas.fillRounded(card, .{ .radius = 8, .color = palette.surface0 });`
pub fn fillRounded(canvas: *Canvas, area: core.Rect, fill_value: RoundedFill) !void {
    if (area.isEmpty()) {
        return;
    }

    try canvas.fillRoundedAt(canvas.rect(area), fill_value);
}

/// `fillRounded` over a device-pixel rectangle. A radius larger than half
/// the shorter side is clamped, so `999` draws a pill.
/// Example: `try canvas.fillRoundedAt(pill, .{ .radius = 999, .color = palette.accent });`
pub fn fillRoundedAt(canvas: *Canvas, bounds: Rect, fill_value: RoundedFill) !void {
    if (bounds.width <= 0 or bounds.height <= 0) {
        return;
    }

    try canvas.quads.pushRounded(bounds, .{
        .fill = canvas.color(fill_value.color, canvas.theme.terminal.background),
        .radius = clampRadius(bounds, fill_value.radius),
    });
}

/// Strokes a band of `width` device pixels inside the area's outline and
/// leaves the interior transparent. One quad, like `fill`.
/// Example: `try canvas.ring(pane.outer, .{ .width = 2, .color = palette.yellow });`
pub fn ring(canvas: *Canvas, area: core.Rect, stroke: Ring) !void {
    if (area.isEmpty()) {
        return;
    }

    try canvas.ringAt(canvas.rect(area), stroke);
}

/// `ring` over a device-pixel rectangle; `stroke.alpha` fades the band.
/// Example: `try canvas.ringAt(inset, .{ .width = 2, .color = palette.yellow, .alpha = 0.5 });`
pub fn ringAt(canvas: *Canvas, bounds: Rect, stroke: Ring) !void {
    if (bounds.width <= 0 or bounds.height <= 0) {
        return;
    }

    var border_color = canvas.color(stroke.color, canvas.theme.terminal.foreground);
    border_color.a *= stroke.alpha;
    try canvas.quads.pushRounded(bounds, .{
        .fill = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .radius = clampRadius(bounds, stroke.radius),
        .border = stroke.width,
        .border_color = border_color,
    });
}

/// Draws one sprite cell scaled into `bounds` with linear sampling: the page
/// cell is sized for the display scale, so an on-grid box samples one texel
/// per pixel and any residual ratio is a bilinear average of premultiplied
/// texels. One quad, no shape. The top-left corner is snapped to a whole
/// pixel so linear sampling never blurs an exact-size mark.
/// Example: `try canvas.spriteAt(mark_box, sprite);`
pub fn spriteAt(canvas: *Canvas, bounds: Rect, sprite: Sprite) !void {
    const page = canvas.sprites orelse return;
    if (bounds.width <= 0 or bounds.height <= 0) {
        return;
    }

    const snapped: Rect = .{ .x = @floor(bounds.x), .y = @floor(bounds.y), .width = bounds.width, .height = bounds.height };
    try canvas.quads.pushSprite(snapped, .{ .uv = page.uv(sprite) });
}

/// The embedded mark of a built-in provider when the canvas has a page.
/// Example: `if (canvas.providerMark(agent.provider)) |mark| ...`
pub fn providerMark(canvas: *const Canvas, provider: core.AgentProvider) ?Sprite {
    const page = canvas.sprites orelse return null;
    return page.providerMark(provider);
}

/// Fills a device-pixel rectangle with the terminal background at `alpha`,
/// which dims whatever was painted before it. One quad.
/// Example: `try canvas.dimAt(content, 0.15);`
pub fn dimAt(canvas: *Canvas, bounds: Rect, alpha: f32) !void {
    if (bounds.width <= 0 or bounds.height <= 0) {
        return;
    }

    var shade = canvas.color(.default, canvas.theme.terminal.background);
    shade.a = alpha;
    try canvas.quads.pushRect(bounds, shade);
}

/// Monospace labels advance one cell per column and clip at grapheme
/// boundaries; sans labels shape as one HarfBuzz run with proportional
/// advances at the label's size role and clip at the area's pixel edge, so
/// callers measure first when they need whole tokens. Cached glyphs bypass
/// shaping and rasterization after warmup.
/// Example: `try canvas.text(area, .{ .text = "Workspace", .bold = true, .face = .sans, .size = .body });`
pub fn text(canvas: *Canvas, area: core.Rect, label: Label) !void {
    if (area.isEmpty()) {
        return;
    }

    _ = try canvas.textAt(canvas.rect(area.row(0)), label);
}

/// `text` over a device-pixel rectangle: the label's natural line box is
/// centred vertically inside `bounds`, so a row taller or shorter than the
/// box keeps its glyphs on one baseline, clipped at the rectangle's edges.
/// Returns the painted advance in pixels so a caller can lay out the next
/// token.
/// Example: `const width = try canvas.textAt(row, .{ .text = title, .bold = true, .face = .sans, .size = .title });`
pub fn textAt(canvas: *Canvas, bounds: Rect, label: Label) !f32 {
    if (bounds.width <= 0 or bounds.height <= 0) {
        return 0;
    }

    const line = try canvas.lineBox(label);
    const baseline = @floor(bounds.y + (bounds.height - line.height) / 2) + line.ascender;
    return canvas.paintLabel(.{ .bounds = bounds, .baseline = baseline, .line = line }, label);
}

fn paintLabel(canvas: *Canvas, placement: LabelPlacement, label: Label) !f32 {
    const bounds = placement.bounds;
    const baseline = placement.baseline;
    const first = canvas.quads.items().len;
    const ink = canvas.labelInk(label);
    const pen: [2]f32 = .{ bounds.x, baseline };
    const width = switch (label.face) {
        .mono => try canvas.monoText(placement, label),
        .sans => @min(bounds.width, try canvas.atlas.place(canvas.run(label, pen), canvas.quads)),
    };
    const top = baseline - placement.line.ascender;
    if (label.underline and width != 0) {
        try canvas.quads.pushRect(.{ .x = bounds.x, .y = top + placement.line.height - 2, .width = width, .height = 1 }, ink);
    }

    if (label.strikethrough and width != 0) {
        try canvas.quads.pushRect(.{ .x = bounds.x, .y = top + placement.line.height * 0.5, .width = width, .height = 1 }, ink);
    }

    canvas.quads.clipFrom(first, bounds);
    return width;
}

// A terminal-sized or monospace label sits in the cell box, so it shares a
// baseline with the cells beside it; a sized sans label uses Plex's own box.
fn lineBox(canvas: *Canvas, label: Label) !LineBox {
    const pixel_height = canvas.chrome.text(label.size);
    if (label.face == .mono or pixel_height == null) {
        return .{ .ascender = canvas.metrics.baseline, .height = @floatFromInt(canvas.metrics.cell_height) };
    }

    return canvas.atlas.lineBox(if (label.bold) .sans_semibold else .sans, pixel_height.?);
}

/// Returns the device-pixel width `text` would paint without clipping, so a
/// caller can right-align or drop tokens before painting. Warm sans labels
/// only read the shaping cache; monospace labels count cells.
/// Example: `const width = try canvas.measure(.{ .text = "hace 3m", .face = .sans });`
pub fn measure(canvas: *Canvas, label: Label) !f32 {
    return switch (label.face) {
        .mono => @floatFromInt(@as(u32, core.measure(label.text)) * canvas.metrics.cell_width),
        .sans => try canvas.atlas.measure(canvas.run(label, .{ 0, 0 })),
    };
}

fn monoText(canvas: *Canvas, placement: LabelPlacement, label: Label) !f32 {
    const bounds = placement.bounds;
    const baseline = placement.baseline;
    const ink = canvas.labelInk(label);
    const columns: u16 = @intFromFloat(@min(65535, @floor(bounds.width / @as(f32, @floatFromInt(canvas.metrics.cell_width)))));
    var iterator: core.GraphemeIterator = .{ .bytes = label.text };
    var column: u16 = 0;
    while (column < columns) {
        const cluster = iterator.next() orelse break;
        if (cluster.width > columns - column) {
            break;
        }

        _ = try canvas.atlas.place(.{
            .text = cluster.bytes,
            .x = bounds.x + @as(f32, @floatFromInt(@as(u32, column) * canvas.metrics.cell_width)),
            .y = baseline,
            .pixel_height = canvas.metrics.pixel_height,
            .cell_bounds = canvas.metrics.glyphCell(),
            .color = ink,
            .bold = label.bold,
            .italic = label.italic,
        }, canvas.quads);
        column += cluster.width;
    }

    return @floatFromInt(@as(u32, column) * canvas.metrics.cell_width);
}

// Bold sans selects the real SemiBold face, never synthetic emboldening. A
// sized label lets fallback glyphs fit a cell of its own height rather
// than the terminal's.
fn run(canvas: *Canvas, label: Label, pen: [2]f32) TextRun {
    const sized = canvas.chrome.text(label.size);
    return .{
        .text = label.text,
        .x = pen[0],
        .y = pen[1],
        .pixel_height = sized orelse canvas.metrics.pixel_height,
        .cell_bounds = if (sized == null) canvas.metrics.glyphCell() else null,
        .color = canvas.labelInk(label),
        .bold = false,
        .italic = label.italic,
        .face = if (label.bold) .sans_semibold else .sans,
    };
}

fn labelInk(canvas: Canvas, label: Label) Color {
    var value = canvas.color(label.color, canvas.theme.terminal.foreground);
    if (label.faint) {
        value.a *= 0.5;
    }

    value.a *= label.alpha;
    return value;
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

fn clampRadius(bounds: Rect, radius: f32) f32 {
    return @min(radius, @min(bounds.width, bounds.height) / 2);
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
