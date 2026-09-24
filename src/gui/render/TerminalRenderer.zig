//! Converts runtime cells into a bounded native frame. No VT parsing lives here.
const frame_budget = @import("frame_budget.zig");
const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const FontSource = @import("../text/FontSource.zig");
const GlyphAtlas = @import("../text/GlyphAtlas.zig");
const SpritePage = @import("../image/SpritePage.zig");
const QuadList = @import("QuadList.zig");
const gfx = @import("gfx");
const Color = gfx.Color;
const Rect = gfx.Rect;
const colors = @import("cell_colors.zig");
const Metrics = @import("../TerminalMetrics.zig");
const ChromeMetrics = @import("../widgets/ChromeMetrics.zig");
const SidebarBand = @import("../widgets/SidebarBand.zig");
const SidebarRequest = @import("../widgets/SidebarRequest.zig");
const native = @import("../native/native.zig");
const Renderer = @This();
const RetainedCells = @import("RetainedCells.zig");
const CellPaint = @import("CellPaint.zig");
const CellMesh = @import("CellMesh.zig");
const CursorPaint = @import("CursorPaint.zig");
const copy_selection = @import("copy_selection.zig");
const InkTarget = @import("InkTarget.zig");
const Quad = gfx.Quad.Quad;

allocator: std.mem.Allocator,
/// Reads discovered fallback font files; `configured` sets it, and a
/// renderer without one never looks for installed faces.
io: ?std.Io = null,
config: client.GuiConfig = .{},
theme: data.TerminalTheme = data.theme_support.default_theme.terminal,
font: FontSource = .{},
atlas: ?GlyphAtlas = null,
/// Built with the atlas for the same display scale; favicons land in it
/// between frames and bump its version the way glyphs bump the atlas.
sprites: ?SpritePage = null,
/// Supplied by the GUI image store before prepare; borrowed through frame completion.
diagrams: [8]native.DiagramTexture = @splat(.{}),
quads: QuadList,
cell_quads: QuadList,
retained: RetainedCells,
repainted_cells: usize = 0,
metrics: Metrics = .{ .cell_width = 1, .cell_height = 1, .baseline = 0, .pixel_height = 15 },
chrome: ChromeMetrics = .{},
/// What the next measurement asks of the sidebar band; the host sets it
/// from the shared visibility and its width preference before measuring.
sidebar_request: SidebarRequest = .{},
/// The band the last measurement took off the left of the grid.
sidebar: SidebarBand = .{},
scale: f32 = 0,
origin: [2]u32 = .{ 0, 0 },
viewport: [2]u32 = .{ 0, 0 },
atlas_version: u32 = 0,
last_page_version: u32 = 0,
sprites_version: u32 = 0,
last_sprites_version: u32 = 0,
background: Color = .black,
foreground: Color = .white,
last_theme: ?data.TerminalTheme = null,
cursor_on: bool = true,
focused: bool = true,

pub fn init(allocator: std.mem.Allocator) Renderer {
    return .{
        .allocator = allocator,
        .quads = .init(allocator),
        .cell_quads = .init(allocator),
        .retained = .init(allocator),
    };
}

/// Builds a replacement independently; callers swap it only after GPU consumers finish.
/// Example: `var renderer = try Renderer.configured(gpa, io, .{ .config = config.gui });`
pub fn configured(allocator: std.mem.Allocator, io: std.Io, options: RendererOptions) !Renderer {
    var renderer = Renderer.init(allocator);
    errdefer renderer.deinit();
    renderer.io = io;
    renderer.config = options.config;
    renderer.theme = options.theme;
    renderer.font = try FontSource.load(allocator, io, &options.config.font.family);
    _ = try renderer.measure(options.viewport);
    return renderer;
}

pub fn deinit(self: *Renderer) void {
    if (self.atlas) |*atlas| {
        atlas.deinit();
    }

    if (self.sprites) |*sprites| {
        sprites.deinit();
    }

    self.font.deinit(self.allocator);

    self.quads.deinit();
    self.cell_quads.deinit();
    self.retained.deinit();
}

/// Resolves physical font metrics before the shared client is constructed.
/// Example: `const size = try renderer.measure(viewport);`
pub fn measure(self: *Renderer, viewport: native.Viewport) !core.TerminalSize {
    if (!std.math.isFinite(viewport.scale) or viewport.scale <= 0 or viewport.scale > 8) {
        return error.InvalidDisplayScale;
    }

    if (self.atlas == null or self.scale != viewport.scale) {
        const pixel_height: u16 = @intFromFloat(@round(self.config.font.scaledSize(viewport.scale)));
        var replacement = try GlyphAtlas.init(
            self.allocator,
            .{
                .font = self.font.bytes,
                .pixel_height = pixel_height,
                .face_index = self.font.match.face_index,
                .postscript = std.mem.sliceTo(&self.font.match.postscript, 0),
                .thicken = self.config.font.thicken,
                .thicken_strength = self.config.font.thicken_strength,
                .io = self.io,
            },
        );
        errdefer replacement.deinit();
        try replacement.prepareFallbacks();
        var sprites = try SpritePage.init(self.allocator, SpritePage.cellFor(viewport.scale));
        errdefer sprites.deinit();
        const natural_height: f32 = @floatFromInt(try replacement.lineHeight(pixel_height));
        const height = @round(natural_height * self.config.font.line_height);
        const width = @round(@as(f32, @floatFromInt(try replacement.cellWidth(pixel_height))) + self.config.font.letter_spacing * viewport.scale);

        if (height < 1 or height > 65535 or width < 1 or width > 65535) {
            return error.InvalidFontSpacing;
        }

        self.metrics = .{
            .cell_width = @intFromFloat(width),
            .cell_height = @intFromFloat(height),
            .baseline = @as(f32, @floatFromInt(try replacement.ascender(pixel_height))) + (height - natural_height) / 2,
            .pixel_height = pixel_height,
        };
        if (self.atlas) |*atlas| {
            atlas.deinit();
        }

        if (self.sprites) |*page| {
            page.deinit();
        }

        self.retained.invalidate();
        self.atlas = replacement;
        self.sprites = sprites;
        self.scale = viewport.scale;
        self.last_page_version = 0;
        self.last_sprites_version = 0;
    }

    // Chrome bands come off the window first, in whole device pixels, so
    // the grid beside and below them holds complete cells and the PTY never
    // sees chrome. The sidebar band and its gap replace the left padding.
    const chrome = ChromeMetrics.resolve(self.config, viewport.scale).fit(viewport.height, self.metrics.cell_height);
    const body_height = viewport.height -| chrome.vertical();
    const padding = self.config.window.padding;
    const x = @min(@as(u32, @intFromFloat(@round(padding.x * viewport.scale))), (viewport.width -| self.metrics.cell_width) / 2);
    const y = @min(@as(u32, @intFromFloat(@round(padding.y * viewport.scale))), (body_height -| self.metrics.cell_height) / 2);
    const sidebar = SidebarBand.resolve(self.sidebar_request, .{ .width = viewport.width, .cell_width = self.metrics.cell_width, .padding_x = x, .scale = viewport.scale });
    const left = if (sidebar.visible()) sidebar.reserved() else x;

    const size = try self.metrics.measure(.{
        .width = viewport.width -| left -| x,
        .height = body_height -| (2 * y),
        .scale = viewport.scale,
    });

    self.chrome = chrome;
    self.sidebar = sidebar;
    self.origin = .{ left, chrome.top_bar + y };
    self.viewport = .{ viewport.width, viewport.height };
    const cells = @as(usize, size.cols) * size.rows;

    if (cells > RetainedCells.max_cells) {
        return error.NativeCellBudgetExceeded;
    }

    try self.quads.reserve(frame_budget.quads(cells));
    try self.cell_quads.reserve(CellMesh.capacity);
    try self.retained.resize(.{
        size.cols,
        size.rows,
    });
    return size;
}

/// Starts a frame without traversing the model or emitting any quads. The
/// widget composition decides which terminal leaves to draw afterwards.
/// Example: `renderer.begin();`
pub fn begin(self: *Renderer) void {
    self.quads.clear();
    self.repainted_cells = 0;
    const background = rgb(self.theme.background);
    const foreground = rgb(self.theme.foreground);

    if (self.last_theme == null or !self.theme.sameCells(self.last_theme.?)) {
        self.retained.invalidate();
    }

    self.last_theme = self.theme;
    self.background = background;
    self.foreground = foreground;
}

/// Terminal-only preparation for renderer probes. The GUI composes its complete
/// widget list in Scene instead. Example: `try renderer.prepare(projection);`
pub fn prepare(self: *Renderer, projection: client.Projection) !data.PresentationCommit {
    self.begin();
    const tab = projection.tab orelse return .{};
    const model = projection.model;
    const location = model.tabs.location[tab];
    const layout = projection.layout.?;
    var commit: data.PresentationCommit = .{
        .location = if (model.panes.countIn(location.tab_id) == 0) null else location,
    };
    for (layout.views()) |view| {
        if (view.surface != .terminal) {
            continue;
        }

        const pane = model.panes.findInConst(location.tab_id, view.pane_id) orelse continue;
        try self.drawPane(.{
            .pane = pane,
            .view = view,
            .copy = copy_selection.forPane(projection.copy, pane.id),
            .hide_cursor = projection.prompt != null,
        });
        commit.append(pane);
    }

    return commit;
}

/// Seals the atlas and the sprite page after terminal cells, native chrome
/// and overlays share them; each frame version advances only when its page
/// changed, so the backend uploads once per change and never on a warm frame.
/// Example: `renderer.seal();`
pub fn seal(self: *Renderer) void {
    const page_version = self.atlas.?.version;
    if (self.last_page_version != page_version) {
        self.last_page_version = page_version;
        self.atlas_version +%= 1;
    }

    const sprites_version = if (self.sprites) |page| page.version else 0;
    if (self.last_sprites_version != sprites_version) {
        self.last_sprites_version = sprites_version;
        self.sprites_version +%= 1;
    }
}

const PanePaint = @import("PanePaint.zig");
const RendererOptions = @import("RendererOptions.zig");

/// The Canvas terminal operation reuses retained cell meshes and cursor policy.
/// Example: `try renderer.drawPane(paint);`
pub fn drawPane(self: *Renderer, paint: PanePaint) !void {
    core.profiling.add(.gui_pane_draw, 1);
    var visited: u64 = 0;
    var ink_visited: u64 = 0;
    var hits: u64 = 0;
    var rebuilt: u64 = 0;
    var item_calls: u64 = 0;
    const quads_before = self.quads.items().len;

    defer {
        core.profiling.add(.gui_cell_visit, visited);
        core.profiling.add(.gui_ink_visit, ink_visited);
        core.profiling.add(.mesh_compare, visited);
        core.profiling.add(.mesh_hit, hits);
        core.profiling.add(.mesh_rebuild, rebuilt);
        core.profiling.add(.mesh_items, item_calls);
        core.profiling.add(.gui_quads, self.quads.items().len - quads_before);
    }

    const pane = paint.pane;
    const area = paint.view.content;
    const rows: u16 = @min(area.h, pane.buffer.h);
    const cols: u16 = @min(area.w, pane.buffer.w);
    for (0..rows) |row| {
        const y = area.y + @as(u16, @intCast(row));
        const source = pane.buffer.cells[row * pane.buffer.w ..][0..cols];
        const retained = self.retained.row(.{ area.x, y }, cols);
        for (source, retained.metadata, 0..) |*original, *metadata, col| {
            // Only a selected cell needs a projected copy; every other cell
            // is compared in place in the pane buffer.
            var selected: core.Cell = undefined;
            const cell: *const core.Cell = if (paint.copy) |copy| projected: {
                if (!copy.selected(@intCast(col), pane.scroll.offset + @as(u32, @intCast(row)))) {
                    break :projected original;
                }

                selected = original.*;
                selected.style.flags.inverse = !selected.style.flags.inverse;
                break :projected &selected;
            } else original;

            const rect = self.cellRect(.{
                .x = area.x + @as(u16, @intCast(col)),
                .y = y,
                .w = @intCast(@min(@max(1, cell.width), cols - col)),
                .h = 1,
            });
            const mesh = retained.at(col);
            visited += 1;
            if (!mesh.matchesCell(cell, rect)) {
                const key: CellPaint = .{
                    .cell = cell.*,
                    .rect = rect,
                };
                try self.paintCell(key);
                mesh.replace(key, self.cell_quads.items());
                mesh.classifyBackground(self.background);
                self.repainted_cells += 1;
                rebuilt += 1;
            } else {
                hits += 1;
            }

            if (metadata.background) {
                item_calls += 1;
                try self.quads.push(mesh.background());
            }
        }
    }

    const cursor = self.paneCursor(paint);
    if (cursor) |visible| {
        if (visible.style == .block) {
            try visible.paint(&self.quads);
        }
    }

    // Backgrounds and the block cursor precede natural ink. The cell anchor
    // owns its color; italic overhang remains visible across adjacent cells.
    const bounds = self.cellRect(area);
    for (0..rows) |row| {
        const retained = self.retained.row(.{ area.x, area.y + @as(u16, @intCast(row)) }, cols);
        for (retained.metadata, 0..) |*metadata, col| {
            ink_visited += 1;
            if (metadata.len <= 1) {
                continue;
            }

            item_calls += 1;
            const mesh = retained.at(col);
            const target: InkTarget = .{
                .bounds = bounds,
                .color = if (cursor) |visible| visible.inkColor(metadata.paint.rect) else null,
            };
            try self.pushInk(mesh.primaryInk(), target);
            try self.pushInk(mesh.overflowInk(), target);
        }
    }

    if (cursor) |visible| {
        if (visible.style != .block) {
            try visible.paint(&self.quads);
        }
    }
}

/// Appends retained ink clipped to its pane, recolored under a block cursor.
fn pushInk(self: *Renderer, ink: []const Quad, target: InkTarget) !void {
    for (ink) |original| {
        var item = original;
        if (target.color) |override| {
            item.r = override.r;
            item.g = override.g;
            item.b = override.b;
            item.a = override.a;
        }

        try self.quads.pushClipped(item, target.bounds);
    }
}

fn paneCursor(self: *const Renderer, paint: PanePaint) ?CursorPaint {
    const pane = paint.pane;
    const area = paint.view.content;
    const rows = @min(area.h, pane.buffer.h);
    const cols = @min(area.w, pane.buffer.w);
    const visible_cursor = copy_selection.cursor(pane, paint.copy);
    if (!paint.hide_cursor and paint.view.focused and visible_cursor.visible and self.cursor_on and visible_cursor.x < cols and visible_cursor.y < rows) {
        var col = visible_cursor.x;
        const row = visible_cursor.y;
        if (col > 0 and pane.buffer.cells[@as(usize, row) * pane.buffer.w + col].width == 0) {
            col -= 1;
        }

        const cell = pane.buffer.cells[@as(usize, row) * pane.buffer.w + col];
        return .{
            .rect = self.cellRect(.{ .x = area.x + col, .y = area.y + row, .w = @min(@max(1, cell.width), cols - col), .h = 1 }),
            .style = if (!self.focused) .hollow else switch (visible_cursor.appearance.shape) {
                .default => self.config.cursor.style,
                .block => .block,
                .bar => .bar,
                .underline => .underline,
                .hollow => .hollow,
            },
            .color = if (self.theme.cursor_color) |c| rgb(c) else self.foreground,
            .text_color = if (self.theme.cursor_text_color) |c| rgb(c) else self.background,
            .thickness = @max(1, @round(self.scale * 2)),
        };
    }

    return null;
}

fn paintCell(self: *Renderer, paint: CellPaint) !void {
    const cell = paint.cell;
    const rect = paint.rect;
    const list = &self.cell_quads;
    list.clear();
    const background = self.color(if (cell.style.flags.inverse) cell.style.fg else cell.style.bg, if (cell.style.flags.inverse) self.foreground else self.background);
    var background_rect = rect;
    background_rect.width = @floatFromInt(self.metrics.cell_width);
    try list.pushRect(background_rect, background);
    if (cell.width == 0 or cell.style.flags.invisible) {
        return;
    }

    var ink = self.color(if (cell.style.flags.inverse) cell.style.bg else cell.style.fg, if (cell.style.flags.inverse) self.background else self.foreground);
    if (cell.style.flags.faint) {
        ink.a *= 0.5;
    }

    if (!std.mem.eql(u8, cell.text(), " ")) {
        _ = try self.atlas.?.place(.{ .text = cell.text(), .x = rect.x, .y = rect.y + self.metrics.baseline, .color = ink, .pixel_height = self.metrics.pixel_height, .cell_bounds = self.metrics.glyphCell(), .bold = cell.style.flags.bold, .italic = cell.style.flags.italic }, list);
    }

    if (cell.style.flags.underline != .none) {
        try list.pushRect(.{ .x = rect.x, .y = rect.y + rect.height - 2, .width = rect.width, .height = 1 }, self.color(cell.style.underline_color, ink));
    }

    if (cell.style.flags.strikethrough) {
        try list.pushRect(.{ .x = rect.x, .y = rect.y + rect.height * 0.5, .width = rect.width, .height = 1 }, ink);
    }
}

fn cellRect(self: *const Renderer, cells: core.Rect) Rect {
    return self.metrics.rect(self.origin, cells);
}

fn color(self: *const Renderer, value: core.Color, fallback: Color) Color {
    return colors.withPalette(value, fallback, &self.theme.palette);
}

fn rgb(value: [3]u8) Color {
    return Color.rgb(value[0], value[1], value[2]);
}

pub fn frame(self: *const Renderer, token: u64) native.Frame {
    const quads = self.quads.items();
    return .{
        .token = token,
        .quads = quads.ptr,
        .quad_count = @intCast(quads.len),
        .atlas = if (self.atlas) |atlas| atlas.pixels.ptr else null,
        .atlas_side = GlyphAtlas.side,
        .atlas_version = self.atlas_version,
        .sprites = if (self.sprites) |page| page.pixels.ptr else null,
        .sprites_side = if (self.sprites != null) SpritePage.side else 0,
        .sprites_version = self.sprites_version,
        .diagrams = self.diagrams,
        .background = .{ self.background.r, self.background.g, self.background.b, self.config.window.background_opacity },
        .background_blur = self.config.window.background_blur,
        .titlebar = @intFromBool(self.config.window.titlebar),
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

test "diagram frame snapshots borrow pixels and preserve versions through replace and clear" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    const pixels = [_]u8{ 128, 0, 0, 128 };
    renderer.diagrams[7] = .{ .pixels = &pixels, .width = 1, .height = 1, .version = 0x100000001 };
    const first = renderer.frame(1);
    try std.testing.expectEqual(pixels[0..].ptr, first.diagrams[7].pixels.?);
    renderer.diagrams[7].version = 2;
    const second = renderer.frame(2);
    try std.testing.expectEqual(@as(u64, 0x100000001), first.diagrams[7].version);
    try std.testing.expectEqual(@as(u64, 2), second.diagrams[7].version);
    renderer.diagrams[7] = .{};
    const cleared = renderer.frame(3);
    try std.testing.expectEqual(@as(?[*]const u8, null), cleared.diagrams[7].pixels);
    try std.testing.expectEqual(@as(u32, 1), first.diagrams[7].width);
    try native.DiagramTexture.validate(&first.diagrams);
    try native.DiagramTexture.validate(&cleared.diagrams);
}
