//! Converts runtime cells into a bounded native frame. No VT parsing lives here.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const FontSource = @import("../text/FontSource.zig");
const GlyphAtlas = @import("../text/GlyphAtlas.zig");
const SpritePage = @import("../image/SpritePage.zig");
const QuadList = @import("QuadList.zig");
const Color = @import("Color.zig");
const Rect = @import("Rect.zig");
const colors = @import("cell_colors.zig");
const Metrics = @import("../TerminalMetrics.zig");
const ChromeMetrics = @import("../chrome/ChromeMetrics.zig");
const native = @import("../native/native.zig");
const Renderer = @This();
const RetainedCells = @import("RetainedCells.zig");
const CellPaint = @import("CellPaint.zig");
const CellMesh = @import("CellMesh.zig");
const CursorPaint = @import("CursorPaint.zig");
const copy_selection = @import("copy_selection.zig");

allocator: std.mem.Allocator,
/// Reads discovered fallback font files; `configured` sets it, and a
/// renderer without one never looks for installed faces.
io: ?std.Io = null,
config: client.GuiConfig = .{},
theme: client.TerminalTheme = client.theme_support.default_theme.terminal,
font: FontSource = .{},
atlas: ?GlyphAtlas = null,
/// Built with the atlas for the same display scale; favicons land in it
/// between frames and bump its version the way glyphs bump the atlas.
sprites: ?SpritePage = null,
quads: QuadList,
cell_quads: QuadList,
retained: RetainedCells,
repainted_cells: usize = 0,
metrics: Metrics = .{ .cell_width = 1, .cell_height = 1, .baseline = 0, .pixel_height = 15 },
chrome: ChromeMetrics = .{},
scale: f32 = 0,
origin: [2]u32 = .{ 0, 0 },
viewport: [2]u32 = .{ 0, 0 },
atlas_version: u32 = 0,
last_page_version: u32 = 0,
sprites_version: u32 = 0,
last_sprites_version: u32 = 0,
background: Color = .black,
foreground: Color = .white,
last_theme: ?client.TerminalTheme = null,
cursor_on: bool = true,
focused: bool = true,

pub fn init(allocator: std.mem.Allocator) Renderer {
    return .{ .allocator = allocator, .quads = .init(allocator), .cell_quads = .init(allocator), .retained = .init(allocator) };
}

/// Builds a replacement independently; callers swap it only after GPU consumers finish.
/// Example: `var renderer = try Renderer.configured(gpa, io, .{ .config = config.gui });`
pub fn configured(allocator: std.mem.Allocator, io: std.Io, options: @import("RendererOptions.zig")) !Renderer {
    var renderer = Renderer.init(allocator);
    errdefer renderer.deinit();
    renderer.io = io;
    renderer.config = options.config;
    renderer.theme = options.theme;
    renderer.font = try FontSource.load(allocator, io, &options.config.font.family);
    _ = try renderer.measure(options.viewport);
    return renderer;
}

pub fn deinit(renderer: *Renderer) void {
    if (renderer.atlas) |*atlas| {
        atlas.deinit();
    }

    if (renderer.sprites) |*sprites| {
        sprites.deinit();
    }

    renderer.font.deinit(renderer.allocator);

    renderer.quads.deinit();
    renderer.cell_quads.deinit();
    renderer.retained.deinit();
}

/// Resolves physical font metrics before the shared client is constructed.
/// Example: `const size = try renderer.measure(viewport);`
pub fn measure(renderer: *Renderer, viewport: native.Viewport) !core.TerminalSize {
    if (!std.math.isFinite(viewport.scale) or viewport.scale <= 0 or viewport.scale > 8) {
        return error.InvalidDisplayScale;
    }

    if (renderer.atlas == null or renderer.scale != viewport.scale) {
        const pixel_height: u16 = @intFromFloat(@round(renderer.config.font.scaledSize(viewport.scale)));
        var replacement = try GlyphAtlas.init(renderer.allocator, .{ .font = renderer.font.bytes, .pixel_height = pixel_height, .face_index = renderer.font.match.face_index, .postscript = std.mem.sliceTo(&renderer.font.match.postscript, 0), .thicken = renderer.config.font.thicken, .thicken_strength = renderer.config.font.thicken_strength, .io = renderer.io });
        errdefer replacement.deinit();
        try replacement.prepareFallbacks();
        var sprites = try SpritePage.init(renderer.allocator, SpritePage.cellFor(viewport.scale));
        errdefer sprites.deinit();
        const natural_height: f32 = @floatFromInt(try replacement.lineHeight(pixel_height));
        const height = @round(natural_height * renderer.config.font.line_height);
        const width = @round(@as(f32, @floatFromInt(try replacement.cellWidth(pixel_height))) + renderer.config.font.letter_spacing * viewport.scale);
        if (height < 1 or height > 65535 or width < 1 or width > 65535) {
            return error.InvalidFontSpacing;
        }

        renderer.metrics = .{
            .cell_width = @intFromFloat(width),
            .cell_height = @intFromFloat(height),
            .baseline = @as(f32, @floatFromInt(try replacement.ascender(pixel_height))) + (height - natural_height) / 2,
            .pixel_height = pixel_height,
        };
        if (renderer.atlas) |*atlas| {
            atlas.deinit();
        }

        if (renderer.sprites) |*page| {
            page.deinit();
        }

        renderer.retained.invalidate();
        renderer.atlas = replacement;
        renderer.sprites = sprites;
        renderer.scale = viewport.scale;
        renderer.last_page_version = 0;
        renderer.last_sprites_version = 0;
    }

    // Chrome bands come off the window first, in whole device pixels, so
    // the grid below them holds complete cells and the PTY never sees chrome.
    const chrome = ChromeMetrics.resolve(renderer.config, viewport.scale).fit(viewport.height, renderer.metrics.cell_height);
    const body_height = viewport.height -| chrome.vertical();
    const padding = renderer.config.window.padding;
    const x = @min(@as(u32, @intFromFloat(@round(padding.x * viewport.scale))), (viewport.width -| renderer.metrics.cell_width) / 2);
    const y = @min(@as(u32, @intFromFloat(@round(padding.y * viewport.scale))), (body_height -| renderer.metrics.cell_height) / 2);
    const size = try renderer.metrics.measure(.{
        .width = viewport.width -| (2 * x),
        .height = body_height -| (2 * y),
        .scale = viewport.scale,
    });
    renderer.chrome = chrome;
    renderer.origin = .{ x, chrome.top_bar + chrome.tab_strip + y };
    renderer.viewport = .{ viewport.width, viewport.height };
    const cells = @as(usize, size.cols) * size.rows;
    if (cells > RetainedCells.max_cells) {
        return error.NativeCellBudgetExceeded;
    }

    try renderer.quads.reserve(@import("frame_budget.zig").quads(cells));
    try renderer.cell_quads.reserve(CellMesh.capacity);
    try renderer.retained.resize(.{ size.cols, size.rows });
    return size;
}

/// Copies the visible leaves into quads while the projection is borrowed.
/// Example: `const commit = try renderer.prepare(projection);`
pub fn prepare(renderer: *Renderer, projection: client.Projection) !client.PresentationCommit {
    renderer.quads.clear();
    renderer.repainted_cells = 0;
    const background = rgb(renderer.theme.background);
    const foreground = rgb(renderer.theme.foreground);
    if (renderer.last_theme == null or !renderer.theme.sameCells(renderer.last_theme.?)) {
        renderer.retained.invalidate();
    }

    renderer.last_theme = renderer.theme;
    renderer.background = background;
    renderer.foreground = foreground;
    const model = projection.model orelse return .{};
    var layout: client.LayoutSnapshot = .{};
    model.layout.snapshot(projection.geometry.area, &layout);
    var commit: client.PresentationCommit = .{ .location = model.location };
    for (layout.views()) |view| {
        if (view.surface != .terminal) {
            continue;
        }

        const pane = model.findConst(view.pane_id) orelse continue;
        try renderer.paintPane(.{ .pane = pane, .view = view, .copy = copy_selection.forPane(projection.copy, pane.id), .hide_cursor = projection.prompt != null });
        commit.append(pane);
    }

    return commit;
}

/// Seals the atlas and the sprite page after terminal cells, native chrome
/// and overlays share them; each frame version advances only when its page
/// changed, so the backend uploads once per change and never on a warm frame.
/// Example: `renderer.seal();`
pub fn seal(renderer: *Renderer) void {
    const page_version = renderer.atlas.?.version;
    if (renderer.last_page_version != page_version) {
        renderer.last_page_version = page_version;
        renderer.atlas_version +%= 1;
    }

    const sprites_version = if (renderer.sprites) |page| page.version else 0;
    if (renderer.last_sprites_version != sprites_version) {
        renderer.last_sprites_version = sprites_version;
        renderer.sprites_version +%= 1;
    }
}

const PanePaint = @import("PanePaint.zig");

fn paintPane(renderer: *Renderer, paint: PanePaint) !void {
    const pane = paint.pane;
    const area = paint.view.content;
    const rows = @min(area.h, pane.buffer.h);
    const cols = @min(area.w, pane.buffer.w);
    for (0..rows) |row| {
        for (0..cols) |col| {
            var cell = pane.buffer.cells[row * pane.buffer.w + col];
            if (paint.copy) |copy| {
                if (copy.selected(@intCast(col), pane.scroll.offset + @as(u32, @intCast(row)))) {
                    cell.style.flags.inverse = !cell.style.flags.inverse;
                }
            }
            const position: [2]u16 = .{ area.x + @as(u16, @intCast(col)), area.y + @as(u16, @intCast(row)) };
            const key: CellPaint = .{ .cell = cell, .rect = renderer.cellRect(.{ .x = position[0], .y = position[1], .w = @intCast(@min(@max(1, cell.width), cols - col)), .h = 1 }) };
            const mesh = renderer.retained.at(position);
            if (!mesh.matches(key)) {
                try renderer.paintCell(key);
                mesh.replace(key, renderer.cell_quads.items());
                renderer.repainted_cells += 1;
            }

            const background = mesh.items()[0];
            if (background.r != renderer.background.r or background.g != renderer.background.g or background.b != renderer.background.b) {
                try renderer.quads.push(background);
            }
        }
    }

    const cursor = renderer.paneCursor(paint);
    if (cursor) |visible| {
        if (visible.style == .block) {
            try visible.paint(&renderer.quads);
        }
    }

    // Backgrounds and the block cursor precede natural ink. The cell anchor
    // owns its color; italic overhang remains visible across adjacent cells.
    const bounds = renderer.cellRect(area);
    for (0..rows) |row| {
        for (0..cols) |col| {
            const mesh = renderer.retained.at(.{ area.x + @as(u16, @intCast(col)), area.y + @as(u16, @intCast(row)) });
            const cursor_color = if (cursor) |visible| visible.inkColor(mesh.paint.rect) else null;
            for (mesh.items()[1..]) |original| {
                var item = original;
                if (cursor_color) |override| {
                    item.r = override.r;
                    item.g = override.g;
                    item.b = override.b;
                    item.a = override.a;
                }

                try renderer.quads.pushClipped(item, bounds);
            }
        }
    }

    if (cursor) |visible| {
        if (visible.style != .block) {
            try visible.paint(&renderer.quads);
        }
    }
}

fn paneCursor(renderer: *const Renderer, paint: PanePaint) ?CursorPaint {
    const pane = paint.pane;
    const area = paint.view.content;
    const rows = @min(area.h, pane.buffer.h);
    const cols = @min(area.w, pane.buffer.w);
    const visible_cursor = copy_selection.cursor(pane, paint.copy);
    if (!paint.hide_cursor and paint.view.focused and visible_cursor.visible and renderer.cursor_on and visible_cursor.x < cols and visible_cursor.y < rows) {
        var col = visible_cursor.x;
        const row = visible_cursor.y;
        if (col > 0 and pane.buffer.cells[@as(usize, row) * pane.buffer.w + col].width == 0) {
            col -= 1;
        }

        const cell = pane.buffer.cells[@as(usize, row) * pane.buffer.w + col];
        return .{
            .rect = renderer.cellRect(.{ .x = area.x + col, .y = area.y + row, .w = @min(@max(1, cell.width), cols - col), .h = 1 }),
            .style = if (!renderer.focused) .hollow else switch (visible_cursor.appearance.shape) {
                .default => renderer.config.cursor.style,
                .block => .block,
                .bar => .bar,
                .underline => .underline,
                .hollow => .hollow,
            },
            .color = if (renderer.theme.cursor_color) |c| rgb(c) else renderer.foreground,
            .text_color = if (renderer.theme.cursor_text_color) |c| rgb(c) else renderer.background,
            .thickness = @max(1, @round(renderer.scale * 2)),
        };
    }

    return null;
}

fn paintCell(renderer: *Renderer, paint: CellPaint) !void {
    const cell = paint.cell;
    const rect = paint.rect;
    const list = &renderer.cell_quads;
    list.clear();
    const background = renderer.color(if (cell.style.flags.inverse) cell.style.fg else cell.style.bg, if (cell.style.flags.inverse) renderer.foreground else renderer.background);
    var background_rect = rect;
    background_rect.width = @floatFromInt(renderer.metrics.cell_width);
    try list.pushRect(background_rect, background);
    if (cell.width == 0 or cell.style.flags.invisible) {
        return;
    }

    var ink = renderer.color(if (cell.style.flags.inverse) cell.style.bg else cell.style.fg, if (cell.style.flags.inverse) renderer.background else renderer.foreground);
    if (cell.style.flags.faint) {
        ink.a *= 0.5;
    }

    if (!std.mem.eql(u8, cell.text(), " ")) {
        _ = try renderer.atlas.?.place(.{ .text = cell.text(), .x = rect.x, .y = rect.y + renderer.metrics.baseline, .color = ink, .pixel_height = renderer.metrics.pixel_height, .cell_bounds = renderer.metrics.glyphCell(), .bold = cell.style.flags.bold, .italic = cell.style.flags.italic }, list);
    }

    if (cell.style.flags.underline != .none) {
        try list.pushRect(.{ .x = rect.x, .y = rect.y + rect.height - 2, .width = rect.width, .height = 1 }, renderer.color(cell.style.underline_color, ink));
    }

    if (cell.style.flags.strikethrough) {
        try list.pushRect(.{ .x = rect.x, .y = rect.y + rect.height * 0.5, .width = rect.width, .height = 1 }, ink);
    }
}

fn cellRect(renderer: *const Renderer, cells: core.Rect) Rect {
    return renderer.metrics.rect(renderer.origin, cells);
}

fn color(renderer: *const Renderer, value: core.Color, fallback: Color) Color {
    return colors.withPalette(value, fallback, &renderer.theme.palette);
}

fn rgb(value: [3]u8) Color {
    return Color.rgb(value[0], value[1], value[2]);
}

pub fn frame(renderer: *const Renderer, token: u64) native.Frame {
    const quads = renderer.quads.items();
    return .{
        .token = token,
        .quads = quads.ptr,
        .quad_count = @intCast(quads.len),
        .atlas = if (renderer.atlas) |atlas| atlas.pixels.ptr else null,
        .atlas_side = GlyphAtlas.side,
        .atlas_version = renderer.atlas_version,
        .sprites = if (renderer.sprites) |page| page.pixels.ptr else null,
        .sprites_side = if (renderer.sprites != null) SpritePage.side else 0,
        .sprites_version = renderer.sprites_version,
        .background = .{ renderer.background.r, renderer.background.g, renderer.background.b, renderer.config.window.background_opacity },
        .background_blur = renderer.config.window.background_blur,
        .titlebar = @intFromBool(renderer.config.window.titlebar),
    };
}

test "fallback icons retain their full texture in tightened terminal cells" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    renderer.config.font = .{ .size = 22, .line_height = 0.75, .letter_spacing = -5, .thicken = true };
    var natural = QuadList.init(std.testing.allocator);
    defer natural.deinit();
    for ([_]f32{ 1, 2 }) |scale| {
        _ = try renderer.measure(.{ .width = 800, .height = 600, .scale = scale });
        const rect = renderer.metrics.rect(.{ 4, 7 }, .{ .x = 1, .y = 1, .w = 1, .h = 1 });
        for ([_][]const u8{ "\u{f07b}", "\u{f02db}" }) |icon| {
            var cell: core.Cell = .{ .len = @intCast(icon.len) };
            @memcpy(cell.bytes[0..icon.len], icon);
            for (0..4) |style| {
                cell.style.flags.bold = style & 1 != 0;
                cell.style.flags.italic = style & 2 != 0;
                natural.clear();
                _ = try renderer.atlas.?.place(.{ .text = icon, .x = rect.x, .y = rect.y + renderer.metrics.baseline, .color = .white, .pixel_height = renderer.metrics.pixel_height, .bold = cell.style.flags.bold, .italic = cell.style.flags.italic }, &natural);
                try renderer.paintCell(.{ .cell = cell, .rect = rect });
                const ink = renderer.cell_quads.items()[1..];
                try std.testing.expectEqual(natural.items().len, ink.len);
                for (natural.items(), ink) |source, actual| {
                    try std.testing.expectApproxEqAbs(source.u0, actual.u0, 0.000001);
                    try std.testing.expectApproxEqAbs(source.u1, actual.u1, 0.000001);
                    try std.testing.expectApproxEqAbs(source.v0, actual.v0, 0.000001);
                    try std.testing.expectApproxEqAbs(source.v1, actual.v1, 0.000001);
                    try std.testing.expect(actual.x >= rect.x and actual.y >= rect.y);
                    try std.testing.expect(actual.x + actual.width <= rect.x + rect.width + 0.001);
                    try std.testing.expect(actual.y + actual.height <= rect.y + rect.height + 0.001);
                }
            }
        }
    }
}
