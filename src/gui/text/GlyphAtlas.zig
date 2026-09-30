//! Rasterizes glyphs on demand into one alpha page the GPU samples, and
//! turns shaped text into quads. One page serves every size the client
//! paints at, so a frame samples one texture, and every face keeps one
//! sized instance per height it has painted, so terminal cells and the
//! three chrome sizes shape and rasterize side by side without invalidating
//! one another. Texel (0, 0) stays opaque white so solid rectangles are
//! quads too. Configured and fallback faces share the page.
const cellglyphs = @import("cellglyphs");
const core = @import("telar-core");
const cellgrid = @import("cellgrid");
const BoxInk = cellglyphs.BoxInk;
const GlyphRaster = @import("../native/GlyphRaster.zig");
const assets = @import("assets");
const builtin = @import("builtin");
const font_id = @import("font_id.zig");
const std = @import("std");
const freetype = @import("freetype");
const QuadList = gfx.QuadList;
const gfx = @import("gfx");
const quad = gfx.Quad;
const AtlasOptions = @import("AtlasOptions.zig");
const GlyphSlot = @import("GlyphSlot.zig");
const ShapedRun = @import("ShapedRun.zig");
const TextRun = @import("TextRun.zig");
const GlyphAtlas = @This();
const ShapingCache = @import("ShapingCache.zig");
const ShapingKey = @import("ShapingKey.zig");
const FontSet = @import("FontSet.zig");
const FontRuns = @import("FontRuns.zig");
const FontRun = @import("FontRun.zig");
const ShapedText = @import("ShapedText.zig");
const GlyphFailures = @import("GlyphFailures.zig");
const Braille = cellglyphs.Braille;
const AsciiGlyph = @import("AsciiGlyph.zig");
const AsciiGlyphs = @import("AsciiGlyphs.zig");
const Box = cellglyphs.BoxDrawing;
const Block = cellglyphs.BlockElement;
const BlockInk = cellglyphs.BlockInk;
const BoxGrid = cellglyphs.BoxGrid;
const BoxCurve = cellglyphs.BoxCurve;
const BoxCache = @import("BoxCache.zig");
const Rect = gfx.Rect;
const FontSize = @import("FontSize.zig");
const LineBox = @import("LineBox.zig");
const GlyphId = @import("GlyphId.zig");

extern fn FT_GlyphSlot_Embolden(freetype.c.FT_GlyphSlot) void;
extern fn FT_GlyphSlot_Oblique(freetype.c.FT_GlyphSlot) void;

/// The page's side in texels when it opens. The page is square.
pub const min_side: u32 = 1024;
/// The side a page grows to when one frame alone does not fit `min_side`.
/// `Quad.solid_uv` names texel (0, 0) of a `min_side` page, which is the
/// corner shared by the reserved texels (0, 0) through (1, 1) of a
/// `max_side` page, so a solid quad samples white on both.
pub const max_side: u32 = 2 * min_side;
pub const side_limit = core.Limit.declare("text.glyph_atlas_side", "texels per side", max_side);
/// Frames a page may take to fill before its working set is called too
/// large for it: filling again this soon after opening or emptying is
/// thrash, rasterizing the same glyphs again, not turnover.
pub const refill_frames: u32 = 120;
/// Frames a `max_side` page that thrashes waits before it is emptied again.
pub const eviction_backoff_frames: u32 = refill_frames;

comptime {
    std.debug.assert(quad.solid_uv[0] * @as(f32, @floatFromInt(min_side)) == 0.5);
    std.debug.assert(quad.solid_uv[0] * @as(f32, @floatFromInt(max_side)) == 1);
}
const reserved: u32 = 2;
const padding: u32 = 1;

/// What `settle` did to the page between two frames.
pub const Settled = enum {
    /// The page had room: nothing changed.
    kept,
    /// The page filled and was emptied; glyphs rasterize again on demand.
    emptied,
    /// The page filled within `refill_frames` below `max_side`: the caller
    /// opens a page of `max_side` instead.
    outgrown,
    /// A `max_side` page filled slowly: the caller opens a page of
    /// `min_side` again.
    shrunk,
    /// A `max_side` page filled within `refill_frames`: glyphs past it draw
    /// the replacement glyph until it may be emptied, and the caller reports
    /// `side_limit`.
    exhausted,
};

allocator: std.mem.Allocator,
pixels: []u8,
/// The page's side in texels: `min_side`, or `max_side` once one frame did
/// not fit.
side: u32,
version: u32 = 1,
/// A glyph found no room since the page was last settled.
full: bool = false,
/// Frames drawn from the page since it was opened or emptied.
frames_drawn: u32 = 0,
/// This `max_side` page filled within `refill_frames`: it is emptied again
/// only after `eviction_backoff_frames`.
held: bool = false,
/// Rows written since the backend last took them, half open; empty when
/// the top is not above the bottom.
dirty: [2]u32 = .{ 0, 0 },
evictions: usize = 0,
shelf_x: u32 = reserved + padding,
shelf_y: u32 = 0,
shelf_height: u32 = reserved + padding,
library: freetype.c.FT_Library,
fonts: FontSet,
shaping_revision: u64 = 0,
shaping_buffer: *freetype.c.hb_buffer_t,
/// The terminal cell height: the size fallback glyphs are prepared at.
pixel_height: u16 = 0,
shaping_cache: ShapingCache,
shape_calls: usize = 0,
raster_attempts: usize = 0,
failed_glyphs: GlyphFailures = .{},
boxes: BoxCache = .{},
glyphs: std.AutoHashMapUnmanaged(u64, GlyphSlot) = .empty,
ascii: AsciiGlyphs = .{},

/// `options.font` must outlive the atlas: FreeType borrows memory faces.
/// Example: `var atlas = try GlyphAtlas.init(allocator, .{ .font = face_bytes, .pixel_height = 28 });`
pub fn init(allocator: std.mem.Allocator, options: AtlasOptions) !GlyphAtlas {
    if (options.pixel_height == 0) {
        return error.InvalidPixelHeight;
    }

    if (options.side != min_side and options.side != max_side) {
        return error.InvalidAtlasSide;
    }

    const side = options.side;
    const pixels = try allocator.alloc(u8, side * side);
    errdefer allocator.free(pixels);
    clearPage(pixels, side);

    var library: freetype.c.FT_Library = undefined;
    if (freetype.c.FT_Init_FreeType(&library) != 0) {
        return error.FreeTypeInitFailed;
    }
    errdefer _ = freetype.c.FT_Done_FreeType(library);

    var fonts = try FontSet.init(library, options, pixels);
    errdefer fonts.deinit(allocator);
    const shaping_buffer = freetype.c.hb_buffer_create() orelse return error.ShapingBufferInitFailed;
    errdefer freetype.c.hb_buffer_destroy(shaping_buffer);
    var shaping_cache = try ShapingCache.init(allocator);
    errdefer shaping_cache.deinit(allocator);

    var atlas: GlyphAtlas = .{
        .allocator = allocator,
        .pixels = pixels,
        .side = side,
        .dirty = .{ 0, side },
        .library = library,
        .fonts = fonts,
        .shaping_buffer = shaping_buffer,
        .shaping_cache = shaping_cache,
        .pixel_height = options.pixel_height,
    };
    try atlas.initBoxFallback();
    try atlas.fonts.primary.select(options.pixel_height);
    return atlas;
}

pub fn deinit(self: *GlyphAtlas) void {
    self.shaping_cache.deinit(self.allocator);
    self.glyphs.deinit(self.allocator);
    freetype.c.hb_buffer_destroy(self.shaping_buffer);
    self.fonts.deinit(self.allocator);
    _ = freetype.c.FT_Done_FreeType(self.library);
    self.allocator.free(self.pixels);
    self.* = undefined;
}

/// Distance from the baseline up to the top of the configured font's
/// tallest glyph at `pixel_height`, in pixels.
/// Example: `const baseline = try atlas.ascender(metrics.pixel_height);`
pub fn ascender(self: *GlyphAtlas, pixel_height: u16) !i32 {
    return (try self.fonts.primary.sized(pixel_height)).ascender();
}

/// Measures the monospace grid of the configured font at `pixel_height`.
/// Example: `const width = try atlas.cellWidth(28);`
pub fn cellWidth(self: *GlyphAtlas, pixel_height: u16) !u16 {
    return (try self.fonts.primary.sized(pixel_height)).maxAdvance();
}

/// The configured font's natural line height at `pixel_height`.
/// Example: `const height = try atlas.lineHeight(28);`
pub fn lineHeight(self: *GlyphAtlas, pixel_height: u16) !u32 {
    return (try self.fonts.primary.sized(pixel_height)).lineHeight();
}

/// Vertical metrics of one face at one height, so chrome centres a label's
/// natural line box in a row of any height. Resident heights allocate
/// nothing; a new height creates its sized instance once.
/// Example: `const box = try atlas.lineBox(.sans, chrome.body);`
pub fn lineBox(self: *GlyphAtlas, face: font_id.Id, pixel_height: u16) !LineBox {
    const size = try self.fonts.get(face).sized(pixel_height);
    return .{ .ascender = @floatFromInt(size.ascender()), .height = @floatFromInt(size.lineHeight()) };
}

/// Shapes one line, rasterizes glyphs the page lacks and appends a quad per
/// visible glyph. Returns the pen advance in pixels.
/// Example: `const advance = try atlas.place(.{ .text = "Telar", .x = 32, .y = 64, .color = ink }, &list);`
pub fn place(self: *GlyphAtlas, run: TextRun, list: *QuadList) !f32 {
    if (run.text.len == 0) {
        return 0;
    }

    self.syncFontRevision();
    if (AsciiGlyphs.index(run, self.pixel_height)) |entry| {
        if (self.ascii.find(entry)) |glyph| {
            return paintAscii(run, glyph, list);
        }

        const advance = try self.placeShaped(run, list);
        try self.rememberAscii(run, entry);
        return advance;
    }

    return self.placeShaped(run, list);
}

fn placeShaped(self: *GlyphAtlas, run: TextRun, list: *QuadList) !f32 {
    if (Braille.parse(run.text)) |pattern| {
        return pattern.paint(placedCell(run, try self.gridBounds(run)), run.color, list);
    }

    if (Box.parse(run.text) != null) {
        return self.paintBox(run, list);
    }

    if (Block.parse(run.text) != null) {
        return self.paintBlock(run, list);
    }

    self.syncFontRevision();
    if (self.shaping_cache.find(shapingKey(run.text, run))) |cached| {
        return self.paint(.{ .run = run, .shaped = cached }, list);
    }

    if (!std.unicode.utf8ValidateSlice(run.text)) {
        return error.InvalidUtf8;
    }

    self.discoverFallbacks(run);
    var runs: FontRuns = .{ .fonts = &self.fonts, .iterator = .{ .bytes = run.text }, .preferred = run.face };
    var advance: f32 = 0;
    while (runs.next()) |part| {
        var current = run;
        current.text = part.text;
        current.x += advance;
        advance += switch (part.source) {
            .box => try self.paintBox(current, list),
            .block => try self.paintBlock(current, list),
            .font => try self.paint(.{ .run = current, .shaped = try self.shape(part, run.pixel_height) }, list),
            .braille => |pattern| try pattern.paint(placedCell(current, try self.gridBounds(current)), current.color, list),
        };
    }

    return advance;
}

/// Measures the pen advance `place` would return without appending quads or
/// rasterizing. Warm labels only read the shaping cache, so callers can clip
/// or right-align proportional chrome text on the interactive path.
/// Example: `const width = try atlas.measure(.{ .text = "agents", .x = 0, .y = 0, .color = ink, .pixel_height = 16, .face = .sans });`
pub fn measure(self: *GlyphAtlas, run: TextRun) !f32 {
    if (run.text.len == 0) {
        return 0;
    }

    self.syncFontRevision();
    if (self.shaping_cache.find(shapingKey(run.text, run))) |cached| {
        return self.penAdvance(.{ .run = run, .shaped = cached });
    }

    if (!std.unicode.utf8ValidateSlice(run.text)) {
        return error.InvalidUtf8;
    }

    self.discoverFallbacks(run);

    var runs: FontRuns = .{ .fonts = &self.fonts, .iterator = .{ .bytes = run.text }, .preferred = run.face };
    var total: f32 = 0;
    while (runs.next()) |part| {
        var current = run;
        current.text = part.text;
        total += switch (part.source) {
            .box, .block, .braille => (try self.gridBounds(current)).width,
            .font => try self.penAdvance(.{ .run = current, .shaped = try self.shape(part, run.pixel_height) }),
        };
    }

    return total;
}

// A run reaches here only when its shaping result is not cached, so the
// installed-font lookup and file read happen once per new grapheme and never
// on a warm repaint. Failures keep the replacement glyph.
fn discoverFallbacks(self: *GlyphAtlas, run: TextRun) void {
    var iterator: cellgrid.GraphemeIterator = .{ .bytes = run.text };
    while (iterator.next()) |cluster| {
        if (Braille.parse(cluster.bytes) != null or Box.parse(cluster.bytes) != null) {
            continue;
        }

        if (self.fonts.source(cluster.bytes, run.face) == .primary) {
            _ = self.fonts.discover(self.allocator, cluster.bytes);
        }
    }
}

fn shapingKey(text: []const u8, run: TextRun) ShapingKey {
    return .{ .text = text, .face = run.face, .pixel_height = run.pixel_height };
}

fn initBoxFallback(self: *GlyphAtlas) !void {
    const extent = BoxCache.fallback_extent;
    const grid = try BoxGrid.init(.{ .x = 0, .y = 0, .width = @floatFromInt(extent[0]), .height = @floatFromInt(extent[1]) }, 1);
    for (&self.boxes.fallback, 0..) |*slot_value, curve_index| {
        slot_value.* = try self.rasterBox(grid, @intCast(curve_index));
    }
}

fn paintBox(self: *GlyphAtlas, run: TextRun, list: *QuadList) !f32 {
    const box = Box.parse(run.text).?;
    const bounds = try self.gridBounds(run);
    const face = self.fonts.primary.face.*;
    const thickness: f32 = if (face.units_per_EM == 0 or face.underline_thickness <= 0)
        @max(1, @ceil(@as(f32, @floatFromInt(run.pixel_height)) / 16))
    else
        @max(1, @ceil(@as(f32, @floatFromInt(face.underline_thickness)) * @as(f32, @floatFromInt(run.pixel_height)) / @as(f32, @floatFromInt(face.units_per_EM))));
    var grid = try BoxGrid.init(bounds, thickness);
    if (bounds.width == 0 or bounds.height == 0) {
        return bounds.width;
    }

    if (box.curve()) |curve_index| {
        var slot_value = self.boxes.fallback[curve_index];
        if (self.boxes.entry(grid, curve_index)) |entry| {
            if (entry.pending) {
                entry.pending = false;
                entry.slot = self.rasterBox(grid, curve_index) catch |err| switch (err) {
                    error.AtlasFull, error.GlyphTooLarge => null,
                };
                if (entry.slot != null) {
                    self.boxes.rasterizations += 1;
                    self.version +%= 1;
                }
            }

            slot_value = entry.slot orelse slot_value;
        }

        try list.push(.{
            .x = run.x + bounds.x,
            .y = run.y + bounds.y,
            .width = bounds.width,
            .height = bounds.height,
            .u0 = slot_value.u0,
            .v0 = slot_value.v0,
            .u1 = slot_value.u1,
            .v1 = slot_value.v1,
            .r = run.color.r,
            .g = run.color.g,
            .b = run.color.b,
            .a = run.color.a,
        });
    } else {
        grid.draw(box);
        const ink = try BoxInk.init(&grid);
        try ink.paint(placedCell(run, bounds), run.color, list);
    }

    return bounds.width;
}

// Block elements are solid rectangles of the cell: no raster, cache or atlas work.
fn paintBlock(self: *GlyphAtlas, run: TextRun, list: *QuadList) !f32 {
    const block = Block.parse(run.text).?;
    const bounds = try self.gridBounds(run);
    const ink = try BlockInk.init(bounds, block);
    try ink.paint(placedCell(run, bounds), run.color, list);
    return bounds.width;
}

/// The cell's rectangle in device pixels: `bounds` is relative to the run's
/// baseline origin.
fn placedCell(run: TextRun, bounds: Rect) Rect {
    return .{
        .x = run.x + bounds.x,
        .y = run.y + bounds.y,
        .width = bounds.width,
        .height = bounds.height,
    };
}

fn rasterBox(self: *GlyphAtlas, grid: BoxGrid, curve_index: u3) !GlyphSlot {
    if (grid.width > BoxCache.raster_limit or grid.height > BoxCache.raster_limit) {
        return error.GlyphTooLarge;
    }

    const width: u16 = @intFromFloat(@ceil(grid.width));
    const height: u16 = @intFromFloat(@ceil(grid.height));
    const origin = try self.pack(.{ width, height });
    const curve = BoxCurve.init(grid, curve_index);
    curve.rasterize(.{
        .pixels = self.pixels[origin[1] * self.side + origin[0] ..],
        .stride = self.side,
        .width = width,
        .height = height,
    });
    const scale: f32 = 1.0 / @as(f32, @floatFromInt(self.side));
    return .{
        .u0 = @as(f32, @floatFromInt(origin[0])) * scale,
        .v0 = @as(f32, @floatFromInt(origin[1])) * scale,
        .u1 = @as(f32, @floatFromInt(origin[0] + width)) * scale,
        .v1 = @as(f32, @floatFromInt(origin[1] + height)) * scale,
        .width = width,
        .height = height,
        .left = 0,
        .top = 0,
    };
}

fn gridBounds(self: *GlyphAtlas, run: TextRun) !Rect {
    if (run.pixel_height == 0) {
        return error.InvalidPixelHeight;
    }

    if (run.cell_bounds) |bounds| {
        return bounds;
    }

    return self.naturalCellBounds(run.pixel_height);
}

/// Records a one-byte run that `paint` placed from one natural glyph. Runs
/// shaped into several glyphs or fitted from a fallback keep the full path.
fn rememberAscii(self: *GlyphAtlas, run: TextRun, entry: usize) !void {
    const shaped = self.shaping_cache.find(shapingKey(run.text, run)) orelse return;
    if (shaped.font.fitted() or shaped.glyphs.len != 1) {
        return;
    }

    const position = shaped.positions[0];
    self.ascii.remember(
        entry,
        .{
            .slot = try self.visibleSlot(.{ .font = shaped.font, .index = shaped.glyphs[0].codepoint }, run),
            .x_offset = position.x_offset,
            .y_offset = position.y_offset,
            .x_advance = position.x_advance,
        },
    );
}

/// The natural single-glyph case of `paint`, with the same arithmetic.
fn paintAscii(run: TextRun, glyph: AsciiGlyph, list: *QuadList) !f32 {
    const placed = glyph.slot;
    if (placed.width > 0 and placed.height > 0) {
        const origin: i64 = @intFromFloat(@round(run.x * 64));
        const x = FontSize.round26(origin + glyph.x_offset) + placed.left;
        const y = -FontSize.round26(glyph.y_offset) - placed.top;
        try list.push(.{
            .x = @floatFromInt(x),
            .y = @round(run.y) + @as(f32, @floatFromInt(y)),
            .width = @floatFromInt(placed.width),
            .height = @floatFromInt(placed.height),
            .u0 = placed.u0,
            .v0 = placed.v0,
            .u1 = placed.u1,
            .v1 = placed.v1,
            .r = run.color.r,
            .g = run.color.g,
            .b = run.color.b,
            .a = run.color.a,
        });
    }

    return @floatFromInt(FontSize.round26(@as(i64, glyph.x_advance)));
}

fn paint(self: *GlyphAtlas, text: ShapedText, list: *QuadList) !f32 {
    const run = text.run;
    const shaped = text.shaped;
    const placement = try self.transform(text);
    const origin: i64 = @intFromFloat(@round(run.x * 64));
    var pen_x = origin;
    const natural = !shaped.font.fitted();
    for (shaped.glyphs, shaped.positions) |info, position| {
        const placed = try self.visibleSlot(.{ .font = shaped.font, .index = info.codepoint }, run);
        if (placed.width > 0 and placed.height > 0) {
            const x = FontSize.round26(pen_x - (if (natural) @as(i64, 0) else origin) + position.x_offset) + placed.left;
            const y = -FontSize.round26(position.y_offset) - placed.top;
            try list.push(.{
                .x = if (natural) @floatFromInt(x) else run.x + @as(f32, @floatFromInt(x)) * placement.scale + placement.x,
                .y = if (natural) @round(run.y) + @as(f32, @floatFromInt(y)) else run.y + @as(f32, @floatFromInt(y)) * placement.scale + placement.y,
                .width = @as(f32, @floatFromInt(placed.width)) * placement.scale,
                .height = @as(f32, @floatFromInt(placed.height)) * placement.scale,
                .u0 = placed.u0,
                .v0 = placed.v0,
                .u1 = placed.u1,
                .v1 = placed.v1,
                .r = run.color.r,
                .g = run.color.g,
                .b = run.color.b,
                .a = run.color.a,
            });
        }

        pen_x += position.x_advance;
    }

    return self.penAdvance(text);
}

// Natural faces advance by their shaped pen; fitted fallback ink advances by
// the cells it was fitted into.
fn penAdvance(self: *GlyphAtlas, text: ShapedText) !f32 {
    if (text.shaped.font.fitted()) {
        return (try self.cellBounds(text)).width;
    }

    var pen_x: i64 = 0;
    for (text.shaped.positions) |position| {
        pen_x += position.x_advance;
    }

    return @floatFromInt(FontSize.round26(pen_x));
}

// Only fallback ink is fitted; configured and chrome faces keep their exact metrics.
fn transform(self: *GlyphAtlas, text: ShapedText) !GlyphTransform {
    if (!text.shaped.font.fitted()) {
        return .{};
    }

    var left: f32 = std.math.inf(f32);
    var right: f32 = -std.math.inf(f32);
    var top: f32 = std.math.inf(f32);
    var bottom: f32 = -std.math.inf(f32);
    var pen_x: i64 = 0;
    for (text.shaped.glyphs, text.shaped.positions) |info, position| {
        const placed = try self.visibleSlot(.{ .font = text.shaped.font, .index = info.codepoint }, text.run);
        if (placed.width > 0 and placed.height > 0) {
            const x: f32 = @floatFromInt(FontSize.round26(pen_x + position.x_offset) + placed.left);
            const y: f32 = @floatFromInt(-FontSize.round26(position.y_offset) - placed.top);
            left = @min(left, x);
            right = @max(right, x + @as(f32, @floatFromInt(placed.width)));
            top = @min(top, y);
            bottom = @max(bottom, y + @as(f32, @floatFromInt(placed.height)));
        }

        pen_x += position.x_advance;
    }

    return GlyphTransform.fit(.{ .x = left, .y = top, .width = right - left, .height = bottom - top }, try self.cellBounds(text));
}

fn cellBounds(self: *GlyphAtlas, text: ShapedText) !Rect {
    var bounds = text.run.cell_bounds orelse try self.naturalCellBounds(text.run.pixel_height);
    bounds.width *= @floatFromInt(text.shaped.columns);
    return bounds;
}

// The configured font's cell at `pixel_height`, so fallback ink painted at
// a chrome size fits a cell of that size rather than the terminal's.
fn naturalCellBounds(self: *GlyphAtlas, pixel_height: u16) !Rect {
    const size = try self.fonts.primary.sized(pixel_height);
    return .{
        .x = 0,
        .y = @floatFromInt(-size.ascender()),
        .width = @floatFromInt(size.maxAdvance()),
        .height = @floatFromInt(size.lineHeight()),
    };
}

fn visibleSlot(self: *GlyphAtlas, glyph_id: GlyphId, run: TextRun) !GlyphSlot {
    return self.slot(glyph_id, run) catch |err| switch (err) {
        error.AtlasFull => self.slot(.{}, run),
        else => err,
    };
}

fn slot(self: *GlyphAtlas, glyph_id: GlyphId, run: TextRun) !GlyphSlot {
    const index = glyph_id.index;
    const font = self.fonts.get(glyph_id.font);
    const glyph_key = (@as(u64, @intFromEnum(glyph_id.font)) << 50) | (@as(u64, index) << 18) | (@as(u64, run.pixel_height) << 2) | @as(u64, @intFromBool(run.bold)) | (@as(u64, @intFromBool(run.italic)) << 1);
    if (self.glyphs.get(glyph_key)) |cached| {
        return cached;
    }

    if (self.failed_glyphs.contains(glyph_key)) {
        return error.AtlasFull;
    }

    self.raster_attempts += 1;
    try font.select(run.pixel_height);
    if (font.mac_rasterizer) |*rasterizer| {
        try rasterizer.select(run.pixel_height);
        var glyph = try rasterizer.measure(.{ .index = index, .style = @as(u32, @intFromBool(run.bold)) | (@as(u32, @intFromBool(run.italic)) << 1) });
        const origin = try self.packGlyph(glyph_key, .{ glyph.width, glyph.height });
        glyph.x = origin[0];
        glyph.y = origin[1];
        rasterizer.draw(glyph);
        if (glyph.width != 0 and glyph.height != 0) {
            self.version +%= 1;
        }

        return self.remember(glyph_key, glyph);
    }

    if (freetype.c.FT_Load_Glyph(font.face, index, freetype.c.FT_LOAD_DEFAULT) != 0) {
        return error.GlyphLoadFailed;
    }

    const glyph = font.face.*.glyph;
    if (run.bold) {
        FT_GlyphSlot_Embolden(glyph);
    }

    if (run.italic) {
        FT_GlyphSlot_Oblique(glyph);
    }

    if (freetype.c.FT_Render_Glyph(glyph, freetype.c.FT_RENDER_MODE_NORMAL) != 0) {
        return error.GlyphRenderFailed;
    }

    const bitmap = glyph.*.bitmap;
    if (bitmap.width > 0 and bitmap.pixel_mode != freetype.c.FT_PIXEL_MODE_GRAY) {
        return error.UnsupportedPixelMode;
    }

    const origin = try self.packGlyph(glyph_key, .{ bitmap.width, bitmap.rows });
    if (bitmap.buffer) |buffer| {
        const pitch: usize = @intCast(@abs(bitmap.pitch));
        for (0..bitmap.rows) |row| {
            const source = buffer[row * pitch ..][0..bitmap.width];
            const destination = self.pixels[(origin[1] + row) * self.side + origin[0] ..][0..bitmap.width];
            @memcpy(destination, source);
        }

        self.version +%= 1;
    }

    return self.remember(glyph_key, .{ .index = index, .style = 0, .x = origin[0], .y = origin[1], .width = bitmap.width, .height = bitmap.rows, .left = glyph.*.bitmap_left, .top = glyph.*.bitmap_top });
}

fn remember(self: *GlyphAtlas, key: u64, glyph: GlyphRaster.GlyphRaster) !GlyphSlot {
    const scale: f32 = 1.0 / @as(f32, @floatFromInt(self.side));
    const placed: GlyphSlot = .{
        .u0 = @as(f32, @floatFromInt(glyph.x)) * scale,
        .v0 = @as(f32, @floatFromInt(glyph.y)) * scale,
        .u1 = @as(f32, @floatFromInt(glyph.x + glyph.width)) * scale,
        .v1 = @as(f32, @floatFromInt(glyph.y + glyph.height)) * scale,
        .width = glyph.width,
        .height = glyph.height,
        .left = glyph.left,
        .top = glyph.top,
    };
    try self.glyphs.put(self.allocator, key, placed);
    return placed;
}

fn packGlyph(self: *GlyphAtlas, key: u64, extent: [2]u32) ![2]u32 {
    return self.pack(extent) catch |err| {
        if (err == error.AtlasFull) {
            self.failed_glyphs.remember(key);
        }

        return err;
    };
}

/// Shelf packing: rows of glyphs, each row as tall as its tallest glyph.
/// A full page is an error for this glyph, not a wrap: the frame draws the
/// replacement glyph and `settle` empties the page before the next frame.
fn pack(self: *GlyphAtlas, extent: [2]u32) ![2]u32 {
    const width = extent[0];
    const height = extent[1];
    if (width == 0 or height == 0) {
        return .{ 0, 0 };
    }

    if (width + padding > self.side or height + padding > self.side) {
        return error.GlyphTooLarge;
    }

    if (self.shelf_x + width + padding > self.side) {
        self.shelf_y += self.shelf_height;
        self.shelf_x = 0;
        self.shelf_height = 0;
    }

    if (self.shelf_y + height + padding > self.side) {
        self.full = true;
        return error.AtlasFull;
    }

    const origin: [2]u32 = .{ self.shelf_x, self.shelf_y };
    self.markDirty(origin[1], origin[1] + height);
    self.shelf_x += width + padding;
    self.shelf_height = @max(self.shelf_height, height + padding);
    return origin;
}

fn shape(self: *GlyphAtlas, run: FontRun, pixel_height: u16) !ShapedRun {
    const text = run.text;
    const shaping_key: ShapingKey = .{ .text = text, .face = run.preferred, .pixel_height = pixel_height };
    if (self.findShaped(shaping_key)) |cached| {
        return cached;
    }

    if (!std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidUtf8;
    }

    freetype.c.hb_buffer_reset(self.shaping_buffer);
    freetype.c.hb_buffer_add_utf8(self.shaping_buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
    if (freetype.c.hb_buffer_allocation_successful(self.shaping_buffer) == 0) {
        return error.ShapingFailed;
    }

    freetype.c.hb_buffer_guess_segment_properties(self.shaping_buffer);
    self.shape_calls += 1;
    const face = self.fonts.get(run.source.font);
    try face.select(pixel_height);
    freetype.c.hb_shape(face.shaping_font, self.shaping_buffer, null, 0);
    var glyph_count: c_uint = 0;
    const glyphs = freetype.c.hb_buffer_get_glyph_infos(self.shaping_buffer, &glyph_count) orelse return error.ShapingFailed;
    var position_count: c_uint = 0;
    const positions = freetype.c.hb_buffer_get_glyph_positions(self.shaping_buffer, &position_count) orelse return error.ShapingFailed;
    if (position_count != glyph_count) {
        return error.ShapingFailed;
    }

    const shaped: ShapedRun = .{ .font = run.source.font, .columns = run.columns, .glyphs = glyphs[0..glyph_count], .positions = positions[0..glyph_count], .rtl = freetype.c.hb_buffer_get_direction(self.shaping_buffer) == freetype.c.HB_DIRECTION_RTL };
    self.shaping_cache.remember(shaping_key, shaped);

    return shaped;
}

fn findShaped(self: *GlyphAtlas, key: ShapingKey) ?ShapedRun {
    self.syncFontRevision();
    return self.shaping_cache.find(key);
}

// A newly discovered face can also cover a grapheme previously cached as
// missing. Keys name the preferred face, so the cache must retire those
// results before measurement or painting can reuse them.
fn syncFontRevision(self: *GlyphAtlas) void {
    if (self.shaping_revision == self.fonts.revision) {
        return;
    }

    self.shaping_cache.clear();
    self.ascii.clear();

    self.shaping_revision = self.fonts.revision;
}

test "the page reserves an opaque white block at its origin" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();

    try std.testing.expectEqual(@as(u8, 255), atlas.pixels[0]);
    try std.testing.expectEqual(@as(u8, 255), atlas.pixels[atlas.side + 1]);
    try std.testing.expectEqual(@as(u8, 0), atlas.pixels[reserved]);
}

test "placing text emits one quad per visible glyph and paints the page once per new glyph" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();

    const advance = try atlas.place(.{ .text = "Te la", .x = 0, .y = 16, .color = .white, .pixel_height = 16 }, &list);
    try std.testing.expectEqual(@as(usize, 4), list.items().len);
    try std.testing.expect(advance > 0);
    try std.testing.expectEqual(@as(u32, 5), atlas.version);

    const first = list.items()[0];
    try std.testing.expect(first.u1 > first.u0 and first.v1 > first.v0);
    try std.testing.expect(first.y < 16 and first.y + first.height <= 20);

    list.clear();
    _ = try atlas.place(.{ .text = "Te la", .x = 0, .y = 16, .color = .white, .pixel_height = 16 }, &list);
    try std.testing.expectEqual(@as(u32, 5), atlas.version);
}

test "the same glyph at another size is rasterized again on the same page" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();

    _ = try atlas.place(.{ .text = "T", .x = 0, .y = 16, .color = .white, .pixel_height = 16 }, &list);
    _ = try atlas.place(.{ .text = "T", .x = 0, .y = 32, .color = .white, .pixel_height = 32 }, &list);

    try std.testing.expectEqual(@as(u32, 3), atlas.version);
    try std.testing.expectEqual(@as(u32, 2), atlas.glyphs.count());
    try std.testing.expect(list.items()[1].height > list.items()[0].height);
    try std.testing.expectEqual(@as(u16, 16), atlas.pixel_height);
    try std.testing.expect(try atlas.lineHeight(32) > try atlas.lineHeight(16));
    try std.testing.expect(try atlas.ascender(32) > try atlas.ascender(16));
}

test "alternating heights keep both shaping results and every sized face resident" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    const heights = [_]u16{ 16, 15, 13, 11 };
    for (heights) |height| {
        _ = try atlas.place(.{ .text = "agents", .x = 0, .y = 20, .color = .white, .pixel_height = height, .face = .sans }, &list);
    }

    const calls = atlas.shape_calls;
    const version = atlas.version;
    for (0..3) |_| {
        for (heights) |height| {
            list.clear();
            _ = try atlas.place(.{ .text = "agents", .x = 0, .y = 20, .color = .white, .pixel_height = height, .face = .sans }, &list);
        }
    }

    try std.testing.expectEqual(calls, atlas.shape_calls);
    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expect(try atlas.measure(.{ .text = "agents", .x = 0, .y = 0, .color = .white, .pixel_height = 11, .face = .sans }) < try atlas.measure(.{ .text = "agents", .x = 0, .y = 0, .color = .white, .pixel_height = 15, .face = .sans }));
    var resident: usize = 0;
    for (atlas.fonts.sans.sizes) |slot_value| {
        resident += @intFromBool(slot_value != null);
    }

    try std.testing.expectEqual(@as(usize, 4), resident);
    for (heights) |height| {
        _ = try atlas.fonts.sans.sized(height + 100);
    }

    try std.testing.expectError(error.TooManyFontSizes, atlas.fonts.sans.sized(200));
}

test "a page that cannot hold another glyph fails instead of wrapping" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{
        .font = assets.jetbrains_mono,
        .pixel_height = 16,
    });
    defer atlas.deinit();

    atlas.shelf_y = atlas.side - 4;
    try std.testing.expectError(error.AtlasFull, atlas.pack(.{ 8, 8 }));
    try std.testing.expectError(error.GlyphTooLarge, atlas.pack(.{ atlas.side, 8 }));
}

test "full glyphs are remembered without rejecting smaller glyphs or changing retained coordinates" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    try atlas.prepareFallbacks();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    const existing: TextRun = .{
        .text = "A",
        .x = 0,
        .y = 16,
        .color = .white,
        .pixel_height = 16,
    };
    _ = try atlas.place(existing, &list);
    const retained = list.items()[0];
    const version = atlas.version;
    atlas.shelf_x = 3;
    atlas.shelf_y = atlas.side - 5;
    atlas.shelf_height = 0;
    const missing: TextRun = .{ .text = "W", .x = 0, .y = 16, .color = .white, .pixel_height = 16 };
    list.clear();
    _ = try atlas.place(missing, &list);
    const fallback = list.items()[0];
    const attempts = atlas.raster_attempts;
    try std.testing.expectEqual(version, atlas.version);
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        atlas.allocator = failing.allocator();
        defer atlas.allocator = std.testing.allocator;
        list.allocator = failing.allocator();
        defer list.allocator = std.testing.allocator;
        for (0..120) |_| {
            list.clear();
            _ = try atlas.place(missing, &list);
            try std.testing.expectEqualDeep(fallback, list.items()[0]);
        }

        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }

    try std.testing.expectEqual(attempts, atlas.raster_attempts);
    list.clear();
    _ = try atlas.place(.{ .text = ".", .x = 0, .y = 16, .color = .white, .pixel_height = 16 }, &list);
    try std.testing.expect(atlas.version > version);
    try std.testing.expect(!std.meta.eql(fallback, list.items()[0]));
    list.clear();
    _ = try atlas.place(existing, &list);
    try std.testing.expectEqualDeep(retained, list.items()[0]);

    var replacement = try GlyphAtlas.init(std.testing.allocator, .{
        .font = assets.jetbrains_mono,
        .pixel_height = 16,
    });
    defer replacement.deinit();
    try replacement.prepareFallbacks();
    list.clear();
    _ = try replacement.place(missing, &list);
    try std.testing.expect(!std.meta.eql(fallback, list.items()[0]));
    try std.testing.expect(replacement.version > 1);
}

/// Settles the page between two frames. A page that filled after more than
/// `refill_frames` frames is emptied, so the next frame rasterizes what it
/// shows instead of the replacement glyph. One that filled sooner holds a
/// working set too large for it: below `max_side` it asks for the larger
/// page, and at `max_side` it is emptied at most once every
/// `eviction_backoff_frames`. A `max_side` page that filled slowly asks for
/// the smaller page again, which grows back if the working set needs it.
/// Never call it while a frame's quads point into the page. Returns what it
/// did, so the caller drops retained geometry that sampled the old page.
///
/// ```zig
/// switch (try atlas.settle()) {
///     .kept, .exhausted => {},
///     .emptied => retained.invalidate(),
///     .outgrown => try reopen(GlyphAtlas.max_side),
///     .shrunk => try reopen(GlyphAtlas.min_side),
/// }
/// ```
pub fn settle(self: *GlyphAtlas) !Settled {
    if (!self.full) {
        return .kept;
    }

    const thrashing = self.frames_drawn <= refill_frames;
    if (thrashing and self.side < max_side) {
        return .outgrown;
    }

    if (thrashing) {
        self.held = true;
    }

    if (self.held and self.frames_drawn < eviction_backoff_frames) {
        return .exhausted;
    }

    if (self.side == max_side and !self.held) {
        return .shrunk;
    }

    try self.empty();
    return .emptied;
}

/// Counts a frame drawn from this page; the renderer calls it as it seals
/// the frame, so `settle` sees how long the page took to fill.
/// Example: `atlas.frameDrawn();`
pub fn frameDrawn(self: *GlyphAtlas) void {
    self.frames_drawn +|= 1;
}

/// The rows written since the last call, as a half-open range, and forgets
/// them; empty when nothing changed. The backend uploads only these rows
/// when it holds the page's previous version.
/// Example: `const rows = atlas.takeDirty();`
pub fn takeDirty(self: *GlyphAtlas) [2]u32 {
    const rows: [2]u32 = if (self.dirty[0] < self.dirty[1]) self.dirty else .{ 0, 0 };
    self.dirty = .{ self.side, 0 };
    return rows;
}

fn markDirty(self: *GlyphAtlas, top: u32, bottom: u32) void {
    self.dirty = .{ @min(self.dirty[0], top), @max(self.dirty[1], bottom) };
}

/// Forgets every glyph, box curve and cached ASCII slot and clears the
/// page to its reserved texels, then prepares the replacement glyphs and
/// box fallbacks again. The version advances so the backend uploads it.
fn empty(self: *GlyphAtlas) !void {
    clearPage(self.pixels, self.side);
    self.shelf_x = reserved + padding;
    self.shelf_y = 0;
    self.shelf_height = reserved + padding;
    self.glyphs.clearRetainingCapacity();
    self.ascii.clear();
    self.boxes = .{};
    self.failed_glyphs = .{};
    self.full = false;
    self.held = false;
    self.frames_drawn = 0;
    self.markDirty(0, self.side);
    self.evictions += 1;
    self.version +%= 1;
    try self.initBoxFallback();
    try self.prepareFallbacks();
}

/// Zeroes a page and makes its reserved corner opaque white.
fn clearPage(pixels: []u8, side: u32) void {
    @memset(pixels, 0);
    for (0..reserved) |row| {
        @memset(pixels[row * side ..][0..reserved], 255);
    }
}

/// Reserves fallback glyphs before terminal output fills the atlas.
/// Example: `try atlas.prepareFallbacks();`
pub fn prepareFallbacks(self: *GlyphAtlas) !void {
    for (0..4) |style| {
        _ = try self.slot(.{}, .{
            .text = "",
            .x = 0,
            .y = 0,
            .color = .white,
            .pixel_height = self.pixel_height,
            .bold = style & 1 != 0,
            .italic = style & 2 != 0,
        });
    }
}

test "a full terminal atlas uses its prepared replacement instead of losing the frame" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{
        .font = assets.jetbrains_mono,
        .pixel_height = 16,
    });
    defer atlas.deinit();
    try atlas.prepareFallbacks();
    atlas.shelf_y = atlas.side;
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    _ = try atlas.place(.{
        .text = "new",
        .x = 0,
        .y = 16,
        .color = .white,
        .pixel_height = 16,
        .bold = true,
    }, &list);
    try std.testing.expect(list.items().len > 0);
}

test "a page that fills over many frames is emptied and draws the glyph that did not fit" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{
        .font = assets.jetbrains_mono,
        .pixel_height = 16,
    });
    defer atlas.deinit();
    try atlas.prepareFallbacks();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    try std.testing.expectEqual(Settled.kept, try atlas.settle());
    atlas.frames_drawn = refill_frames + 1;
    atlas.shelf_y = atlas.side;
    _ = try atlas.place(.{
        .text = "Q",
        .x = 0,
        .y = 16,
        .color = .white,
        .pixel_height = 16,
    }, &list);
    const replacement = list.items()[0];
    try std.testing.expect(atlas.full);
    const version = atlas.version;

    try std.testing.expectEqual(Settled.emptied, try atlas.settle());
    try std.testing.expect(!atlas.full);
    try std.testing.expect(atlas.version != version);
    try std.testing.expectEqual(@as(usize, 1), atlas.evictions);
    try std.testing.expectEqual(@as(u32, 0), atlas.frames_drawn);
    try std.testing.expectEqual(@as(u8, 255), atlas.pixels[0]);
    list.clear();
    _ = try atlas.place(.{
        .text = "Q",
        .x = 0,
        .y = 16,
        .color = .white,
        .pixel_height = 16,
    }, &list);
    try std.testing.expect(!std.meta.eql(replacement, list.items()[0]));
    try std.testing.expect(!atlas.full);
}

test "the first frame that fills a new page asks for the larger page" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{
        .font = assets.jetbrains_mono,
        .pixel_height = 16,
    });
    defer atlas.deinit();
    try atlas.prepareFallbacks();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    try std.testing.expectEqual(Settled.kept, try atlas.settle());
    atlas.shelf_y = atlas.side;
    _ = try atlas.place(.{
        .text = "Q",
        .x = 0,
        .y = 16,
        .color = .white,
        .pixel_height = 16,
    }, &list);
    atlas.frameDrawn();
    try std.testing.expectEqual(Settled.outgrown, try atlas.settle());

    var larger = try GlyphAtlas.init(std.testing.allocator, .{
        .font = assets.jetbrains_mono,
        .pixel_height = 16,
        .side = max_side,
    });
    defer larger.deinit();
    try larger.prepareFallbacks();
    try std.testing.expectEqual(max_side, larger.side);
    try std.testing.expectEqual(@as(u8, 255), larger.pixels[max_side + 1]);
    list.clear();
    _ = try larger.place(.{
        .text = "Q",
        .x = 0,
        .y = 16,
        .color = .white,
        .pixel_height = 16,
    }, &list);
    try std.testing.expect(!larger.full);
    try std.testing.expectError(error.InvalidAtlasSide, GlyphAtlas.init(std.testing.allocator, .{
        .font = assets.jetbrains_mono,
        .pixel_height = 16,
        .side = 4096,
    }));
}

test "a page emptied and filled again within a few frames asks for the larger page" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{
        .font = assets.jetbrains_mono,
        .pixel_height = 16,
    });
    defer atlas.deinit();
    try atlas.prepareFallbacks();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    atlas.frames_drawn = refill_frames + 1;
    atlas.shelf_y = atlas.side;
    _ = try atlas.place(.{
        .text = "Q",
        .x = 0,
        .y = 16,
        .color = .white,
        .pixel_height = 16,
    }, &list);
    try std.testing.expectEqual(Settled.emptied, try atlas.settle());

    // Scrolling a large working set refills the page three frames later.
    for (0..3) |_| {
        atlas.frameDrawn();
    }

    atlas.shelf_y = atlas.side;
    _ = try atlas.place(.{
        .text = "R",
        .x = 0,
        .y = 16,
        .color = .white,
        .pixel_height = 16,
    }, &list);
    try std.testing.expectEqual(Settled.outgrown, try atlas.settle());
}

test "a largest page that thrashes waits before emptying and one that fills slowly shrinks" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{
        .font = assets.jetbrains_mono,
        .pixel_height = 16,
        .side = max_side,
    });
    defer atlas.deinit();
    try atlas.prepareFallbacks();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    atlas.shelf_y = atlas.side;
    _ = try atlas.place(.{
        .text = "Q",
        .x = 0,
        .y = 16,
        .color = .white,
        .pixel_height = 16,
    }, &list);
    atlas.frameDrawn();
    try std.testing.expectEqual(Settled.exhausted, try atlas.settle());
    try std.testing.expect(atlas.held);
    while (atlas.frames_drawn + 1 < eviction_backoff_frames) {
        atlas.frameDrawn();
        try std.testing.expectEqual(Settled.exhausted, try atlas.settle());
    }

    atlas.frameDrawn();
    try std.testing.expectEqual(Settled.emptied, try atlas.settle());
    try std.testing.expect(!atlas.held);
    try std.testing.expectEqual(@as(usize, 1), atlas.evictions);

    atlas.frames_drawn = refill_frames + 1;
    atlas.shelf_y = atlas.side;
    _ = try atlas.place(.{
        .text = "R",
        .x = 0,
        .y = 16,
        .color = .white,
        .pixel_height = 16,
    }, &list);
    try std.testing.expectEqual(Settled.shrunk, try atlas.settle());
}

test "the page reports only the rows written since the backend last took them" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{
        .font = assets.jetbrains_mono,
        .pixel_height = 16,
    });
    defer atlas.deinit();
    try std.testing.expectEqual([2]u32{ 0, atlas.side }, atlas.takeDirty());
    try std.testing.expectEqual([2]u32{ 0, 0 }, atlas.takeDirty());
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    atlas.shelf_y = 100;
    _ = try atlas.place(.{
        .text = "Q",
        .x = 0,
        .y = 16,
        .color = .white,
        .pixel_height = 16,
    }, &list);
    const rows = atlas.takeDirty();
    try std.testing.expect(rows[0] >= 100 and rows[1] > rows[0] and rows[1] <= 100 + 32);
    try std.testing.expectEqual([2]u32{ 0, 0 }, atlas.takeDirty());
}

test "shaping reuse preserves Unicode positions and stays independent of paint styling" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    const run: TextRun = .{ .text = "e\u{301}", .x = 0, .y = 16, .color = .white, .pixel_height = 16 };
    const advance = try atlas.place(run, &list);
    const first = list.items()[0];
    const calls = atlas.shape_calls;
    list.clear();
    var moved = run;
    moved.x = 20;
    moved.y = 40;
    moved.color = .black;
    try std.testing.expectEqual(advance, try atlas.place(moved, &list));
    try std.testing.expectEqual(calls, atlas.shape_calls);
    try std.testing.expectEqual(first.x + 20, list.items()[0].x);
    try std.testing.expectEqual(first.y + 24, list.items()[0].y);
    try std.testing.expectEqual(first.u0, list.items()[0].u0);
    try std.testing.expectEqual(@as(f32, 0), list.items()[0].r);
    moved.bold = true;
    moved.italic = true;
    _ = try atlas.place(moved, &list);
    try std.testing.expectEqual(calls, atlas.shape_calls);
    moved.pixel_height = 32;
    _ = try atlas.place(moved, &list);
    try std.testing.expectEqual(calls + 1, atlas.shape_calls);
}

test "shaping cache eviction and size changes match uncached geometry" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var reference = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer reference.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    for (0..600) |index| {
        var bytes: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&bytes, "{d}", .{index});
        const run: TextRun = .{ .text = text, .x = 5, .y = 20, .color = .white, .pixel_height = 16 };
        list.clear();
        const advance = try atlas.place(run, &list);
        const expected = try std.testing.allocator.dupe(quad.Quad, list.items());
        defer std.testing.allocator.free(expected);
        list.clear();
        reference.shaping_cache.clear();
        try std.testing.expectEqual(advance, try reference.place(run, &list));
        try std.testing.expectEqualSlices(quad.Quad, expected, list.items());
    }
}

test "labels through 64 glyphs reuse shaping with exact uncached geometry" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var reference = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer reference.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    var expected = QuadList.init(std.testing.allocator);
    defer expected.deinit();
    const text = "Investigate terminal rendering and agent history performance today";
    for (32..66) |len| {
        for ([_]u16{ 13, 15, 20 }) |height| {
            var run: TextRun = .{ .text = text[0..len], .face = .sans, .x = 5, .y = 20, .color = .white, .pixel_height = height };
            list.clear();
            _ = try atlas.measure(run);
            _ = try atlas.place(run, &list);
            expected.clear();
            _ = try reference.measure(run);
            _ = try reference.place(run, &expected);
            const calls = atlas.shape_calls;
            run.x = 17;
            run.color = .black;
            run.bold = true;
            run.italic = true;
            list.clear();
            expected.clear();
            reference.shaping_cache.clear();
            try std.testing.expectEqual(try reference.measure(run), try atlas.measure(run));
            try std.testing.expectEqual(try reference.place(run, &expected), try atlas.place(run, &list));
            try std.testing.expectEqualSlices(quad.Quad, expected.items(), list.items());
            try std.testing.expectEqual(calls + @as(usize, if (len <= 64) 0 else 2), atlas.shape_calls);
        }
    }
}

test "single ASCII glyphs remain cached while Unicode runs replace hashed entries" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    for (32..127) |codepoint| {
        const byte = [_]u8{@intCast(codepoint)};
        list.clear();
        _ = try atlas.place(.{ .text = &byte, .x = 0, .y = 16, .color = .white, .pixel_height = 16 }, &list);
    }

    const unicode_run: TextRun = .{ .text = "e\u{301}", .x = 0, .y = 16, .color = .white, .pixel_height = 16 };
    list.clear();
    const advance = try atlas.place(unicode_run, &list);
    const glyphs = try std.testing.allocator.dupe(quad.Quad, list.items());
    defer std.testing.allocator.free(glyphs);
    for (0..600) |index| {
        var bytes: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&bytes, "é{d}", .{index});
        list.clear();
        _ = try atlas.place(.{ .text = text, .x = 0, .y = 16, .color = .white, .pixel_height = 16 }, &list);
    }

    const calls = atlas.shape_calls;
    for (32..127) |codepoint| {
        const byte = [_]u8{@intCast(codepoint)};
        list.clear();
        _ = try atlas.place(.{ .text = &byte, .x = 0, .y = 16, .color = .white, .pixel_height = 16 }, &list);
    }

    try std.testing.expectEqual(calls, atlas.shape_calls);
    list.clear();
    try std.testing.expectEqual(advance, try atlas.place(unicode_run, &list));
    try std.testing.expectEqualSlices(quad.Quad, glyphs, list.items());
}

test "configured non Nerd font falls back across BMP and supplementary icons without changing metrics" {
    const client = @import("telar-client");
    const Source = @import("FontSource.zig");
    var family: client.FontFamily = .{};
    try family.set("DejaVu Sans Mono");
    var source = Source.load(std.testing.allocator, std.testing.io, &family) catch |err| fallback: {
        if (builtin.os.tag != .macos or err != error.FontFamilyNotFound) {
            return err;
        }

        try family.set("Menlo");
        break :fallback try Source.load(std.testing.allocator, std.testing.io, &family);
    };
    defer source.deinit(std.testing.allocator);
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = source.bytes, .pixel_height = 44, .face_index = source.match.face_index, .postscript = std.mem.sliceTo(&source.match.postscript, 0), .thicken = true });
    defer atlas.deinit();
    const metrics = [3]i64{ try atlas.cellWidth(44), try atlas.lineHeight(44), try atlas.ascender(44) };
    const texts = [_][]const u8{ "A", "e\u{301}", "\u{f07b}", "\u{e620}", "\u{f4bc}", "\u{f03ff}", "\u{f02db}", "\u{f07b}\u{fe0f}" };
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    for (texts, 0..) |text, index| {
        if (index >= 2) {
            try std.testing.expect(!atlas.fonts.primary.covers(text));
            try std.testing.expectEqual(font_id.Id.symbols, atlas.fonts.source(text, .primary));
        } else {
            try std.testing.expectEqual(font_id.Id.primary, atlas.fonts.source(text, .primary));
        }

        for (0..4) |style| {
            list.clear();
            const advance = try atlas.place(.{ .text = text, .x = 0, .y = 44, .color = .white, .pixel_height = 44, .bold = style & 1 != 0, .italic = style & 2 != 0 }, &list);
            try std.testing.expect(list.items().len > 0);
            if (index >= 2) {
                try std.testing.expectEqual(@as(f32, @floatFromInt(try atlas.cellWidth(44))), advance);
                for (list.items()) |item| {
                    try std.testing.expect(item.x >= -0.001);
                    try std.testing.expect(item.x + item.width <= advance + 0.001);
                    try std.testing.expect(item.y >= 44 - @as(f32, @floatFromInt(try atlas.ascender(44))) - 0.001);
                    try std.testing.expect(item.y + item.height <= 44 - @as(f32, @floatFromInt(try atlas.ascender(44))) + @as(f32, @floatFromInt(try atlas.lineHeight(44))) + 0.001);
                }

                const shaped = atlas.shaping_cache.find(.{ .text = text, .pixel_height = 44 }).?;
                try std.testing.expectEqual(font_id.Id.symbols, shaped.font);
                for (shaped.glyphs) |glyph| {
                    try std.testing.expect(glyph.codepoint != 0);
                }
            }
        }
    }

    try std.testing.expectEqual(metrics, [3]i64{ try atlas.cellWidth(44), try atlas.lineHeight(44), try atlas.ascender(44) });
    const calls = atlas.shape_calls;
    const rasters = atlas.raster_attempts;
    const version = atlas.version;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    atlas.allocator = failing.allocator();
    list.allocator = failing.allocator();
    defer {
        atlas.allocator = std.testing.allocator;
        list.allocator = std.testing.allocator;
    }

    for (0..120) |_| {
        for (texts) |text| {
            for (0..4) |style| {
                list.clear();
                _ = try atlas.place(.{ .text = text, .x = 0, .y = 44, .color = .white, .pixel_height = 44, .bold = style & 1 != 0, .italic = style & 2 != 0 }, &list);
            }
        }
    }

    try std.testing.expectEqual(calls, atlas.shape_calls);
    try std.testing.expectEqual(rasters, atlas.raster_attempts);
    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expect(!failing.has_induced_failure);
}

test "equal glyph indices in different faces never alias retained atlas coordinates" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 32 });
    defer atlas.deinit();
    var letter: [1]u8 = .{'A'};
    var candidate_index: freetype.c.FT_UInt = 0;
    var codepoint: freetype.c.FT_ULong = 0;
    for ('A'..'Z' + 1) |byte| {
        letter[0] = @intCast(byte);
        const index = freetype.c.FT_Get_Char_Index(atlas.fonts.primary.face, byte);
        codepoint = freetype.c.FT_Get_First_Char(atlas.fonts.symbols.face, &candidate_index);
        while (candidate_index != 0 and candidate_index != index) {
            codepoint = freetype.c.FT_Get_Next_Char(atlas.fonts.symbols.face, codepoint, &candidate_index);
        }

        if (candidate_index == index) {
            break;
        }
    }

    try std.testing.expect(candidate_index != 0);
    var bytes: [4]u8 = undefined;
    const length = try std.unicode.utf8Encode(@intCast(codepoint), &bytes);
    const icon = bytes[0..length];
    try std.testing.expectEqual(font_id.Id.symbols, atlas.fonts.source(icon, .primary));
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    const text: TextRun = .{ .text = &letter, .x = 0, .y = 32, .color = .white, .pixel_height = 32 };
    _ = try atlas.place(text, &list);
    const primary = list.items()[0];
    list.clear();
    var symbol = text;
    symbol.text = icon;
    _ = try atlas.place(symbol, &list);
    const fallback = list.items()[0];
    try std.testing.expect(primary.u0 != fallback.u0 or primary.v0 != fallback.v0);
    try std.testing.expectEqual(@as(u32, 2), atlas.glyphs.count());
    list.clear();
    _ = try atlas.place(text, &list);
    try std.testing.expectEqualDeep(primary, list.items()[0]);
}

test "fallback text and configured symbols keep one grid and refresh correctly at another size" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.nerd_symbols, .pixel_height = 16 });
    defer atlas.deinit();
    try std.testing.expectEqual(font_id.Id.text, atlas.fonts.source("A", .primary));
    try std.testing.expectEqual(font_id.Id.primary, atlas.fonts.source("\u{f07b}", .primary));
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    const run: TextRun = .{ .text = "A\u{f07b}B", .x = 0, .y = 16, .color = .white, .pixel_height = 16 };
    _ = try atlas.place(run, &list);
    try std.testing.expectEqual(@as(usize, 3), list.items().len);
    const before = list.items()[0];
    const calls = atlas.shape_calls;
    list.clear();
    _ = try atlas.place(run, &list);
    try std.testing.expectEqual(calls, atlas.shape_calls);
    try std.testing.expectEqualDeep(before, list.items()[0]);
    var resized = run;
    resized.pixel_height = 32;
    list.clear();
    _ = try atlas.place(resized, &list);
    try std.testing.expect(list.items()[0].height > before.height);
    try std.testing.expect(atlas.shape_calls > calls);
    list.clear();
    _ = try atlas.place(run, &list);
    try std.testing.expectEqualDeep(before, list.items()[0]);
}

test "mixed primary text and repeated icons use primary cell advances and preserve Unicode shaping" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 32 });
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    var run: TextRun = .{ .text = "A\u{f07b}\u{f02db}e\u{301}", .x = 5, .y = 36, .color = .white, .pixel_height = 32 };
    const width: f32 = @floatFromInt(try atlas.cellWidth(32));
    const advance = try atlas.place(run, &list);
    try std.testing.expectEqual(width * 4, advance);
    const mixed = try std.testing.allocator.dupe(quad.Quad, list.items());
    defer std.testing.allocator.free(mixed);
    try std.testing.expectEqual(@as(usize, 4), mixed.len);
    const clusters = [_][]const u8{ "A", "\u{f07b}", "\u{f02db}", "e\u{301}" };
    for (clusters, 0..) |cluster, index| {
        list.clear();
        run.text = cluster;
        run.x = 5 + @as(f32, @floatFromInt(index)) * width;
        try std.testing.expectEqual(width, try atlas.place(run, &list));
        try std.testing.expectEqualDeep(mixed[index], list.items()[0]);
    }
}

test "Braille never shapes or mutates the atlas even cold and across explicit cell sizes" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16, .thicken = true });
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    try list.reserve(16);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    atlas.allocator = failing.allocator();
    defer atlas.allocator = std.testing.allocator;
    list.allocator = failing.allocator();
    defer list.allocator = std.testing.allocator;
    for (0..256) |mask| {
        var bytes: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(@intCast(0x2800 + mask), &bytes);
        list.clear();
        const advance = try atlas.place(.{ .text = bytes[0..length], .x = 10, .y = 70.5, .color = .white, .pixel_height = 44, .bold = true, .italic = true, .cell_bounds = .{ .x = 0, .y = -50.5, .width = 26, .height = 71 } }, &list);
        try std.testing.expectEqual(@as(f32, 26), advance);
        try std.testing.expectEqual(@as(usize, @popCount(@as(u8, @intCast(mask)))), list.items().len);
    }

    list.clear();
    try std.testing.expectEqual(@as(f32, 52), try atlas.place(.{ .text = "\u{28ff}\u{28ff}", .x = 0, .y = 50, .color = .white, .pixel_height = 44, .cell_bounds = .{ .x = 0, .y = -50, .width = 26, .height = 71 } }, &list));
    try std.testing.expectEqual(@as(usize, 16), list.items().len);
    try std.testing.expectEqual(@as(u32, 1), atlas.version);
    try std.testing.expectEqual(@as(u32, 0), atlas.glyphs.count());
    try std.testing.expectEqual(@as(usize, 0), atlas.shape_calls);
    try std.testing.expectEqual(@as(usize, 0), atlas.raster_attempts);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(u16, 16), atlas.pixel_height);
}

test "mixed text retains contextual shaping around procedural Braille" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var mixed = QuadList.init(std.testing.allocator);
    defer mixed.deinit();
    var separate = QuadList.init(std.testing.allocator);
    defer separate.deinit();
    var run: TextRun = .{ .text = "office\u{2801}e\u{301}ffi", .x = 3.5, .y = 20.25, .color = .white, .pixel_height = 16, .cell_bounds = .{ .x = 0, .y = -17.25, .width = 12, .height = 27 } };
    const advance = try atlas.place(run, &mixed);
    try std.testing.expectEqual(@as(usize, 2), atlas.shape_calls);
    const version = atlas.version;
    var expected_advance: f32 = 0;
    for ([_][]const u8{ "office", "\u{2801}", "e\u{301}ffi" }) |text| {
        run.text = text;
        run.x = 3.5 + expected_advance;
        expected_advance += try atlas.place(run, &separate);
    }

    try std.testing.expectEqual(advance, expected_advance);
    try std.testing.expectEqualSlices(quad.Quad, mixed.items(), separate.items());
    try std.testing.expectEqual(@as(usize, 2), atlas.shape_calls);
    try std.testing.expectEqual(version, atlas.version);
    run.text = "\u{2801}\xff";
    separate.clear();
    try std.testing.expectError(error.InvalidUtf8, atlas.place(run, &separate));
    try std.testing.expectEqual(@as(usize, 0), separate.items().len);
}

test "Braille uses natural metrics when callers omit cell bounds" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    var run: TextRun = .{ .text = "\u{2801}", .x = 0, .y = 0, .color = .white, .pixel_height = 32 };
    const advance = try atlas.place(run, &list);
    try std.testing.expectEqual(@as(u16, 16), atlas.pixel_height);
    try std.testing.expectEqual(@as(f32, @floatFromInt(try atlas.cellWidth(32))), advance);
    try std.testing.expect(try atlas.cellWidth(32) > try atlas.cellWidth(16));
    try std.testing.expectEqual(@as(usize, 1), list.items().len);
    run.pixel_height = 0;
    try std.testing.expectError(error.InvalidPixelHeight, atlas.place(run, &list));
}

test "cached ASCII glyphs place exactly what the shaping path places" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var shaped = QuadList.init(std.testing.allocator);
    defer shaped.deinit();
    var cached = QuadList.init(std.testing.allocator);
    defer cached.deinit();
    const positions = [_][2]f32{ .{ 0, 13 }, .{ 27, 45.5 }, .{ 3.3, 7.75 }, .{ 1920, 1117 } };
    for (0..128) |byte| {
        const text = [_]u8{@intCast(byte)};
        for (0..4) |style| {
            for (positions) |position| {
                const run: TextRun = .{ .text = &text, .x = position[0], .y = position[1], .color = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 }, .pixel_height = 16, .bold = style & 1 != 0, .italic = style & 2 != 0 };
                atlas.ascii.clear();
                shaped.clear();
                const expected = atlas.place(run, &shaped) catch |err| {
                    try std.testing.expectEqual(error.InvalidUtf8, err);
                    continue;
                };
                cached.clear();
                const entry = AsciiGlyphs.index(run, atlas.pixel_height).?;
                const actual = try atlas.place(run, &cached);
                try std.testing.expectEqual(expected, actual);
                try std.testing.expectEqualSlices(quad.Quad, shaped.items(), cached.items());
                if (atlas.ascii.find(entry) == null) {
                    continue;
                }

                cached.clear();
                try std.testing.expectEqual(expected, try atlas.place(run, &cached));
                try std.testing.expectEqualSlices(quad.Quad, shaped.items(), cached.items());
            }
        }
    }
}

/// Fits fallback ink to the configured grid while preserving its aspect ratio.
const GlyphTransform = struct {
    x: f32 = 0,
    y: f32 = 0,
    scale: f32 = 1,

    /// Bounds use coordinates relative to the pen baseline; covered primary text bypasses this.
    /// Example: `const transform = GlyphTransform.fit(ink_bounds, cell_bounds);`
    pub fn fit(ink: Rect, cell: Rect) GlyphTransform {
        if (!std.math.isFinite(ink.width) or ink.width <= 0 or ink.height <= 0) {
            return .{};
        }

        const scale = @min(1, @min(cell.width / ink.width, cell.height / ink.height));
        const top = ink.y * scale;
        const bottom = top + ink.height * scale;
        return .{
            .scale = scale,
            .x = cell.x + (cell.width - ink.width * scale) / 2 - ink.x * scale,
            .y = if (top < cell.y) cell.y - top else if (bottom > cell.y + cell.height) cell.y + cell.height - bottom else 0,
        };
    }
};
