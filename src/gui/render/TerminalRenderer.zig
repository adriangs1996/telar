//! Converts runtime cells into a bounded native frame. No VT parsing lives here.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const assets = @import("assets");
const GlyphAtlas = @import("../text/GlyphAtlas.zig");
const QuadList = @import("QuadList.zig");
const Color = @import("Color.zig");
const Rect = @import("Rect.zig");
const colors = @import("cell_colors.zig");
const Metrics = @import("../TerminalMetrics.zig");
const native = @import("../native/native.zig");
const Renderer = @This();

allocator: std.mem.Allocator,
atlas: ?GlyphAtlas = null,
quads: QuadList,
metrics: Metrics = .{ .cell_width = 1, .cell_height = 1, .baseline = 0, .pixel_height = 15 },
scale: f32 = 0,
atlas_version: u32 = 0,
last_page_version: u32 = 0,
background: Color = .black,
foreground: Color = .white,

pub fn init(allocator: std.mem.Allocator) Renderer {
    return .{ .allocator = allocator, .quads = .init(allocator) };
}

pub fn deinit(renderer: *Renderer) void {
    if (renderer.atlas) |*atlas| {
        atlas.deinit();
    }

    renderer.quads.deinit();
}

/// Resolves physical font metrics before the shared client is constructed.
/// Example: `const size = try renderer.measure(viewport);`
pub fn measure(renderer: *Renderer, viewport: native.Viewport) !core.TerminalSize {
    if (!std.math.isFinite(viewport.scale) or viewport.scale <= 0 or viewport.scale > 8) {
        return error.InvalidDisplayScale;
    }

    if (renderer.atlas == null or renderer.scale != viewport.scale) {
        const pixel_height: u16 = @intFromFloat(@round(15 * viewport.scale));
        var replacement = try GlyphAtlas.init(renderer.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = pixel_height });
        errdefer replacement.deinit();
        try replacement.prepareFallbacks();
        renderer.metrics = .{
            .cell_width = replacement.cellWidth(),
            .cell_height = @intCast(replacement.lineHeight()),
            .baseline = @floatFromInt(replacement.ascender()),
            .pixel_height = pixel_height,
        };
        if (renderer.atlas) |*atlas| {
            atlas.deinit();
        }

        renderer.atlas = replacement;
        renderer.scale = viewport.scale;
        renderer.last_page_version = 0;
    }

    const size = try renderer.metrics.measure(viewport);
    const cells = @as(usize, size.cols) * size.rows;
    if (cells > 65536) {
        return error.NativeCellBudgetExceeded;
    }

    try renderer.quads.reserve(cells * 24);
    return size;
}

/// Copies the visible leaves into quads while the projection is borrowed.
/// Example: `const commit = try renderer.prepare(projection, theme);`
pub fn prepare(renderer: *Renderer, projection: client.Projection, theme: client.ColorTheme) !client.PresentationCommit {
    renderer.quads.clear();
    renderer.background = colors.resolve(theme.palette.panel_bg, .black);
    renderer.foreground = colors.resolve(theme.palette.text, .white);
    const model = projection.model orelse return .{};
    var layout: client.LayoutSnapshot = .{};
    model.layout.snapshot(projection.geometry.area, &layout);
    var commit: client.PresentationCommit = .{ .location = model.location };
    for (layout.views()) |view| {
        if (view.surface != .terminal) {
            continue;
        }

        const pane = model.findConst(view.pane_id) orelse continue;
        try renderer.paintPane(.{ .pane = pane, .view = view });
        commit.append(pane);
    }

    const page_version = renderer.atlas.?.version;
    if (renderer.last_page_version != page_version) {
        renderer.last_page_version = page_version;
        renderer.atlas_version +%= 1;
    }

    return commit;
}

const PanePaint = @import("PanePaint.zig");

fn paintPane(renderer: *Renderer, paint: PanePaint) !void {
    const pane = paint.pane;
    const area = paint.view.content;
    const rows = @min(area.h, pane.buffer.h);
    const cols = @min(area.w, pane.buffer.w);
    for (0..rows) |row| {
        for (0..cols) |col| {
            const cell = &pane.buffer.cells[row * pane.buffer.w + col];
            const background = colors.resolve(if (cell.style.flags.inverse) cell.style.fg else cell.style.bg, if (cell.style.flags.inverse) renderer.foreground else renderer.background);
            try renderer.quads.pushRect(renderer.cellRect(.{ .x = area.x + @as(u16, @intCast(col)), .y = area.y + @as(u16, @intCast(row)), .w = 1, .h = 1 }), background);
        }
    }

    for (0..rows) |row| {
        for (0..cols) |col| {
            const cell = &pane.buffer.cells[row * pane.buffer.w + col];
            if (cell.width == 0 or cell.style.flags.invisible) {
                continue;
            }

            const rect = renderer.cellRect(.{
                .x = area.x + @as(u16, @intCast(col)),
                .y = area.y + @as(u16, @intCast(row)),
                .w = @intCast(@min(cell.width, cols - col)),
                .h = 1,
            });
            var ink = colors.resolve(if (cell.style.flags.inverse) cell.style.bg else cell.style.fg, if (cell.style.flags.inverse) renderer.background else renderer.foreground);
            if (cell.style.flags.faint) {
                ink.a *= 0.5;
            }

            const first = renderer.quads.items().len;
            _ = try renderer.atlas.?.place(.{ .text = cell.text(), .x = rect.x, .y = rect.y + renderer.metrics.baseline, .color = ink, .pixel_height = renderer.metrics.pixel_height, .bold = cell.style.flags.bold, .italic = cell.style.flags.italic }, &renderer.quads);
            renderer.quads.clipFrom(first, rect);
            if (cell.style.flags.underline != .none) {
                try renderer.quads.pushRect(.{ .x = rect.x, .y = rect.y + rect.height - 2, .width = rect.width, .height = 1 }, colors.resolve(cell.style.underline_color, ink));
            }

            if (cell.style.flags.strikethrough) {
                try renderer.quads.pushRect(.{ .x = rect.x, .y = rect.y + rect.height * 0.5, .width = rect.width, .height = 1 }, ink);
            }
        }
    }

    if (paint.view.focused and pane.cursor.visible and pane.cursor.x < cols and pane.cursor.y < rows) {
        var cursor = renderer.cellRect(.{ .x = area.x + pane.cursor.x, .y = area.y + pane.cursor.y, .w = 1, .h = 1 });
        cursor.y += cursor.height - 2;
        cursor.height = 2;
        try renderer.quads.pushRect(cursor, renderer.foreground);
    }
}

fn cellRect(renderer: *const Renderer, cells: core.Rect) Rect {
    return .{
        .x = @floatFromInt(@as(u32, cells.x) * renderer.metrics.cell_width),
        .y = @floatFromInt(@as(u32, cells.y) * renderer.metrics.cell_height),
        .width = @floatFromInt(@as(u32, cells.w) * renderer.metrics.cell_width),
        .height = @floatFromInt(@as(u32, cells.h) * renderer.metrics.cell_height),
    };
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
        .background = .{ renderer.background.r, renderer.background.g, renderer.background.b, 1 },
    };
}
