//! Rasterizes glyphs on demand into one alpha page the GPU samples, and
//! turns shaped text into quads. One page serves every size the client
//! paints at, so a frame samples one texture. Texel (0, 0) stays opaque white
//! so solid rectangles are quads too. Configured and fallback faces share the page.
const std = @import("std");
const freetype = @import("freetype");
const QuadList = @import("../render/QuadList.zig");
const quad = @import("../render/Quad.zig");
const AtlasOptions = @import("AtlasOptions.zig");
const GlyphSlot = @import("GlyphSlot.zig");
const ShapedRun = @import("ShapedRun.zig");
const TextRun = @import("TextRun.zig");
const GlyphAtlas = @This();
const ShapingCache = @import("ShapingCache.zig");
const FontSet = @import("FontSet.zig");
const FontRuns = @import("FontRuns.zig");
const FontRun = @import("FontRun.zig");
const ShapedText = @import("ShapedText.zig");
const Id = @import("font_id.zig").Id;
const GlyphTransform = @import("GlyphTransform.zig");
const GlyphFailures = @import("GlyphFailures.zig");

extern fn FT_GlyphSlot_Embolden(freetype.c.FT_GlyphSlot) void;
extern fn FT_GlyphSlot_Oblique(freetype.c.FT_GlyphSlot) void;

/// One page, square, in texels. `Quad.solid_uv` assumes this side.
pub const side: u32 = 1024;

comptime {
    std.debug.assert(quad.solid_uv[0] * @as(f32, @floatFromInt(side)) == 0.5);
}
const reserved: u32 = 2;
const padding: u32 = 1;

allocator: std.mem.Allocator,
pixels: []u8,
version: u32 = 1,
shelf_x: u32 = reserved + padding,
shelf_y: u32 = 0,
shelf_height: u32 = reserved + padding,
library: freetype.c.FT_Library,
fonts: FontSet,
shaping_buffer: *freetype.c.hb_buffer_t,
pixel_height: u16 = 0,
shaping_cache: ShapingCache,
shape_calls: usize = 0,
raster_attempts: usize = 0,
failed_glyphs: GlyphFailures = .{},
glyphs: std.AutoHashMapUnmanaged(u64, GlyphSlot) = .empty,

/// `options.font` must outlive the atlas: FreeType borrows memory faces.
/// Example: `var atlas = try GlyphAtlas.init(allocator, .{ .font = face_bytes, .pixel_height = 28 });`
pub fn init(allocator: std.mem.Allocator, options: AtlasOptions) !GlyphAtlas {
    if (options.pixel_height == 0) {
        return error.InvalidPixelHeight;
    }

    const pixels = try allocator.alloc(u8, side * side);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);
    for (0..reserved) |row| {
        @memset(pixels[row * side ..][0..reserved], 255);
    }

    var library: freetype.c.FT_Library = undefined;
    if (freetype.c.FT_Init_FreeType(&library) != 0) {
        return error.FreeTypeInitFailed;
    }
    errdefer _ = freetype.c.FT_Done_FreeType(library);

    var fonts = try FontSet.init(library, options, pixels);
    errdefer fonts.deinit();
    const shaping_buffer = freetype.c.hb_buffer_create() orelse return error.ShapingBufferInitFailed;
    errdefer freetype.c.hb_buffer_destroy(shaping_buffer);
    var shaping_cache = try ShapingCache.init(allocator);
    errdefer shaping_cache.deinit(allocator);

    var atlas: GlyphAtlas = .{
        .allocator = allocator,
        .pixels = pixels,
        .library = library,
        .fonts = fonts,
        .shaping_buffer = shaping_buffer,
        .shaping_cache = shaping_cache,
    };
    try atlas.select(options.pixel_height);
    return atlas;
}

/// Makes `pixel_height` the size `ascender`, `lineHeight` and shaping use.
/// Cheap when it is already selected. Example: `try atlas.select(28);`
pub fn select(atlas: *GlyphAtlas, pixel_height: u16) !void {
    if (pixel_height == 0) {
        return error.InvalidPixelHeight;
    }

    if (atlas.pixel_height == pixel_height) {
        return;
    }

    try atlas.fonts.select(pixel_height);
    atlas.pixel_height = pixel_height;
    atlas.shaping_cache.clear();
}

pub fn deinit(atlas: *GlyphAtlas) void {
    atlas.shaping_cache.deinit(atlas.allocator);
    atlas.glyphs.deinit(atlas.allocator);
    freetype.c.hb_buffer_destroy(atlas.shaping_buffer);
    atlas.fonts.deinit();
    _ = freetype.c.FT_Done_FreeType(atlas.library);
    atlas.allocator.free(atlas.pixels);
    atlas.* = undefined;
}

/// Distance from the baseline up to the top of the tallest glyph at the
/// selected size, in pixels.
pub fn ascender(atlas: *const GlyphAtlas) i32 {
    return round26(atlas.fonts.primary.face.*.size.*.metrics.ascender);
}

/// Measures the monospace grid. Example: `const width = atlas.cellWidth();`
pub fn cellWidth(atlas: *const GlyphAtlas) u16 {
    return @intCast(@max(1, round26(atlas.fonts.primary.face.*.size.*.metrics.max_advance)));
}

pub fn lineHeight(atlas: *const GlyphAtlas) u32 {
    return @intCast(@max(1, round26(atlas.fonts.primary.face.*.size.*.metrics.height)));
}

/// Shapes one line, rasterizes glyphs the page lacks and appends a quad per
/// visible glyph. Returns the pen advance in pixels.
/// Example: `const advance = try atlas.place(.{ .text = "Telar", .x = 32, .y = 64, .color = ink }, &list);`
pub fn place(atlas: *GlyphAtlas, run: TextRun, list: *QuadList) !f32 {
    if (run.text.len == 0) {
        return 0;
    }

    try atlas.select(run.pixel_height);
    if (atlas.shaping_cache.find(run.text)) |cached| {
        return atlas.paint(.{ .run = run, .shaped = cached }, list);
    }

    if (!std.unicode.utf8ValidateSlice(run.text)) {
        return error.InvalidUtf8;
    }

    var runs: FontRuns = .{ .fonts = &atlas.fonts, .iterator = .{ .bytes = run.text } };
    var advance: f32 = 0;
    while (runs.next()) |part| {
        var current = run;
        current.text = part.text;
        current.x += advance;
        advance += try atlas.paint(.{ .run = current, .shaped = try atlas.shape(part) }, list);
    }

    return advance;
}

fn paint(atlas: *GlyphAtlas, text: ShapedText, list: *QuadList) !f32 {
    const run = text.run;
    const shaped = text.shaped;
    const placement = try atlas.transform(text);
    const origin: i64 = @intFromFloat(@round(run.x * 64));
    var pen_x = origin;
    for (shaped.glyphs, shaped.positions) |info, position| {
        const placed = try atlas.visibleSlot(.{ .font = shaped.font, .index = info.codepoint }, run);
        if (placed.width > 0 and placed.height > 0) {
            const x = round26(pen_x + position.x_offset) + placed.left;
            const y: i32 = @as(i32, @intFromFloat(@round(run.y))) - round26(position.y_offset) - placed.top;
            try list.push(.{
                .x = run.x + (@as(f32, @floatFromInt(x)) - run.x) * placement.scale + placement.x,
                .y = run.y + (@as(f32, @floatFromInt(y)) - run.y) * placement.scale + placement.y,
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

    return if (shaped.font == .primary) @floatFromInt(round26(pen_x - origin)) else @floatFromInt(shaped.columns * atlas.cellWidth());
}

// Only fallback ink is fitted; the user's configured text keeps its exact metrics.
fn transform(atlas: *GlyphAtlas, text: ShapedText) !GlyphTransform {
    if (text.shaped.font == .primary) {
        return .{};
    }

    var left: f32 = std.math.inf(f32);
    var right: f32 = -std.math.inf(f32);
    var top: f32 = std.math.inf(f32);
    var bottom: f32 = -std.math.inf(f32);
    var pen_x: i64 = 0;
    for (text.shaped.glyphs, text.shaped.positions) |info, position| {
        const placed = try atlas.visibleSlot(.{ .font = text.shaped.font, .index = info.codepoint }, text.run);
        if (placed.width > 0 and placed.height > 0) {
            const x: f32 = @floatFromInt(round26(pen_x + position.x_offset) + placed.left);
            const y: f32 = @floatFromInt(-round26(position.y_offset) - placed.top);
            left = @min(left, x);
            right = @max(right, x + @as(f32, @floatFromInt(placed.width)));
            top = @min(top, y);
            bottom = @max(bottom, y + @as(f32, @floatFromInt(placed.height)));
        }

        pen_x += position.x_advance;
    }

    return GlyphTransform.fit(.{ .x = left, .y = top, .width = right - left, .height = bottom - top }, .{
        .x = 0,
        .y = @floatFromInt(-atlas.ascender()),
        .width = @floatFromInt(text.shaped.columns * atlas.cellWidth()),
        .height = @floatFromInt(atlas.lineHeight()),
    });
}

fn visibleSlot(atlas: *GlyphAtlas, glyph_id: @import("GlyphId.zig"), run: TextRun) !GlyphSlot {
    return atlas.slot(glyph_id, run) catch |err| switch (err) {
        error.AtlasFull => atlas.slot(.{}, run),
        else => err,
    };
}

fn slot(atlas: *GlyphAtlas, glyph_id: @import("GlyphId.zig"), run: TextRun) !GlyphSlot {
    const index = glyph_id.index;
    const font = atlas.fonts.get(glyph_id.font);
    const key = (@as(u64, @intFromEnum(glyph_id.font)) << 50) | (@as(u64, index) << 18) | (@as(u64, atlas.pixel_height) << 2) | @as(u64, @intFromBool(run.bold)) | (@as(u64, @intFromBool(run.italic)) << 1);
    if (atlas.glyphs.get(key)) |cached| {
        return cached;
    }

    if (atlas.failed_glyphs.contains(key)) {
        return error.AtlasFull;
    }

    atlas.raster_attempts += 1;
    if (font.mac_rasterizer) |*rasterizer| {
        var glyph = try rasterizer.measure(.{ .index = index, .style = @as(u32, @intFromBool(run.bold)) | (@as(u32, @intFromBool(run.italic)) << 1) });
        const origin = try atlas.packGlyph(key, .{ glyph.width, glyph.height });
        glyph.x = origin[0];
        glyph.y = origin[1];
        rasterizer.draw(glyph);
        if (glyph.width != 0 and glyph.height != 0) {
            atlas.version +%= 1;
        }

        return atlas.remember(key, glyph);
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

    const origin = try atlas.packGlyph(key, .{ bitmap.width, bitmap.rows });
    if (bitmap.buffer) |buffer| {
        const pitch: usize = @intCast(@abs(bitmap.pitch));
        for (0..bitmap.rows) |row| {
            const source = buffer[row * pitch ..][0..bitmap.width];
            const destination = atlas.pixels[(origin[1] + row) * side + origin[0] ..][0..bitmap.width];
            @memcpy(destination, source);
        }

        atlas.version +%= 1;
    }

    return atlas.remember(key, .{ .index = index, .style = 0, .x = origin[0], .y = origin[1], .width = bitmap.width, .height = bitmap.rows, .left = glyph.*.bitmap_left, .top = glyph.*.bitmap_top });
}

fn remember(atlas: *GlyphAtlas, key: u64, glyph: @import("../native/GlyphRaster.zig").GlyphRaster) !GlyphSlot {
    const scale: f32 = 1.0 / @as(f32, @floatFromInt(side));
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
    try atlas.glyphs.put(atlas.allocator, key, placed);
    return placed;
}

fn packGlyph(atlas: *GlyphAtlas, key: u64, extent: [2]u32) ![2]u32 {
    return atlas.pack(extent) catch |err| {
        if (err == error.AtlasFull) {
            atlas.failed_glyphs.remember(key);
        }

        return err;
    };
}

/// Shelf packing: rows of glyphs, each row as tall as its tallest glyph.
/// Enough for one face at one size; a full page is an error, not a wrap.
fn pack(atlas: *GlyphAtlas, extent: [2]u32) ![2]u32 {
    const width = extent[0];
    const height = extent[1];
    if (width == 0 or height == 0) {
        return .{ 0, 0 };
    }

    if (width + padding > side or height + padding > side) {
        return error.GlyphTooLarge;
    }

    if (atlas.shelf_x + width + padding > side) {
        atlas.shelf_y += atlas.shelf_height;
        atlas.shelf_x = 0;
        atlas.shelf_height = 0;
    }

    if (atlas.shelf_y + height + padding > side) {
        return error.AtlasFull;
    }

    const origin: [2]u32 = .{ atlas.shelf_x, atlas.shelf_y };
    atlas.shelf_x += width + padding;
    atlas.shelf_height = @max(atlas.shelf_height, height + padding);
    return origin;
}

fn shape(atlas: *GlyphAtlas, run: FontRun) !ShapedRun {
    const text = run.text;
    if (atlas.shaping_cache.find(text)) |cached| {
        return cached;
    }

    if (!std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidUtf8;
    }

    freetype.c.hb_buffer_reset(atlas.shaping_buffer);
    freetype.c.hb_buffer_add_utf8(atlas.shaping_buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
    if (freetype.c.hb_buffer_allocation_successful(atlas.shaping_buffer) == 0) {
        return error.ShapingFailed;
    }

    freetype.c.hb_buffer_guess_segment_properties(atlas.shaping_buffer);
    atlas.shape_calls += 1;
    freetype.c.hb_shape(atlas.fonts.get(run.font).shaping_font, atlas.shaping_buffer, null, 0);
    var glyph_count: c_uint = 0;
    const glyphs = freetype.c.hb_buffer_get_glyph_infos(atlas.shaping_buffer, &glyph_count) orelse return error.ShapingFailed;
    var position_count: c_uint = 0;
    const positions = freetype.c.hb_buffer_get_glyph_positions(atlas.shaping_buffer, &position_count) orelse return error.ShapingFailed;
    if (position_count != glyph_count) {
        return error.ShapingFailed;
    }

    const shaped: ShapedRun = .{ .font = run.font, .columns = run.columns, .glyphs = glyphs[0..glyph_count], .positions = positions[0..glyph_count] };
    atlas.shaping_cache.remember(text, shaped);
    return shaped;
}

fn round26(value: anytype) i32 {
    const signed: i64 = @intCast(value);
    return @intCast(if (signed >= 0) (signed + 32) >> 6 else -(((-signed) + 32) >> 6));
}

test "the page reserves an opaque white block at its origin" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();

    try std.testing.expectEqual(@as(u8, 255), atlas.pixels[0]);
    try std.testing.expectEqual(@as(u8, 255), atlas.pixels[side + 1]);
    try std.testing.expectEqual(@as(u8, 0), atlas.pixels[reserved]);
}

test "placing text emits one quad per visible glyph and paints the page once per new glyph" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
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
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();

    _ = try atlas.place(.{ .text = "T", .x = 0, .y = 16, .color = .white, .pixel_height = 16 }, &list);
    _ = try atlas.place(.{ .text = "T", .x = 0, .y = 32, .color = .white, .pixel_height = 32 }, &list);

    try std.testing.expectEqual(@as(u32, 3), atlas.version);
    try std.testing.expectEqual(@as(u32, 2), atlas.glyphs.count());
    try std.testing.expect(list.items()[1].height > list.items()[0].height);
    try std.testing.expectEqual(@as(u16, 32), atlas.pixel_height);
}

test "a page that cannot hold another glyph fails instead of wrapping" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();

    atlas.shelf_y = side - 4;
    try std.testing.expectError(error.AtlasFull, atlas.pack(.{ 8, 8 }));
    try std.testing.expectError(error.GlyphTooLarge, atlas.pack(.{ side, 8 }));
}

test "full glyphs are remembered without rejecting smaller glyphs or changing retained coordinates" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    try atlas.prepareFallbacks();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    const existing: TextRun = .{ .text = "A", .x = 0, .y = 16, .color = .white, .pixel_height = 16 };
    _ = try atlas.place(existing, &list);
    const retained = list.items()[0];
    const version = atlas.version;
    atlas.shelf_x = 3;
    atlas.shelf_y = side - 5;
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

    var replacement = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer replacement.deinit();
    try replacement.prepareFallbacks();
    list.clear();
    _ = try replacement.place(missing, &list);
    try std.testing.expect(!std.meta.eql(fallback, list.items()[0]));
    try std.testing.expect(replacement.version > 1);
}

/// Reserves fallback glyphs before terminal output fills the atlas.
/// Example: `try atlas.prepareFallbacks();`
pub fn prepareFallbacks(atlas: *GlyphAtlas) !void {
    for (0..4) |style| {
        _ = try atlas.slot(.{}, .{ .text = "", .x = 0, .y = 0, .color = .white, .pixel_height = atlas.pixel_height, .bold = style & 1 != 0, .italic = style & 2 != 0 });
    }
}

test "a full terminal atlas uses its prepared replacement instead of losing the frame" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    try atlas.prepareFallbacks();
    atlas.shelf_y = side;
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    _ = try atlas.place(.{ .text = "new", .x = 0, .y = 16, .color = .white, .pixel_height = 16, .bold = true }, &list);
    try std.testing.expect(list.items().len > 0);
}

test "shaping reuse preserves Unicode positions and stays independent of paint styling" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
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
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var reference = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
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

test "single ASCII glyphs remain cached while Unicode runs replace hashed entries" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
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
        if (@import("builtin").os.tag != .macos or err != error.FontFamilyNotFound) {
            return err;
        }

        try family.set("Menlo");
        break :fallback try Source.load(std.testing.allocator, std.testing.io, &family);
    };
    defer source.deinit(std.testing.allocator);
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = source.bytes, .pixel_height = 44, .face_index = source.match.face_index, .postscript = std.mem.sliceTo(&source.match.postscript, 0), .thicken = true });
    defer atlas.deinit();
    const metrics = [3]i64{ atlas.cellWidth(), atlas.lineHeight(), atlas.ascender() };
    const texts = [_][]const u8{ "A", "e\u{301}", "\u{f07b}", "\u{e620}", "\u{f4bc}", "\u{f03ff}", "\u{f02db}", "\u{f07b}\u{fe0f}" };
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    for (texts, 0..) |text, index| {
        if (index >= 2) {
            try std.testing.expect(!atlas.fonts.primary.covers(text));
            try std.testing.expectEqual(Id.symbols, atlas.fonts.source(text));
        } else {
            try std.testing.expectEqual(Id.primary, atlas.fonts.source(text));
        }

        for (0..4) |style| {
            list.clear();
            const advance = try atlas.place(.{ .text = text, .x = 0, .y = 44, .color = .white, .pixel_height = 44, .bold = style & 1 != 0, .italic = style & 2 != 0 }, &list);
            try std.testing.expect(list.items().len > 0);
            if (index >= 2) {
                try std.testing.expectEqual(@as(f32, @floatFromInt(atlas.cellWidth())), advance);
                for (list.items()) |item| {
                    try std.testing.expect(item.x >= -0.001);
                    try std.testing.expect(item.x + item.width <= advance + 0.001);
                    try std.testing.expect(item.y >= 44 - @as(f32, @floatFromInt(atlas.ascender())) - 0.001);
                    try std.testing.expect(item.y + item.height <= 44 - @as(f32, @floatFromInt(atlas.ascender())) + @as(f32, @floatFromInt(atlas.lineHeight())) + 0.001);
                }

                const shaped = atlas.shaping_cache.find(text).?;
                try std.testing.expectEqual(Id.symbols, shaped.font);
                for (shaped.glyphs) |glyph| {
                    try std.testing.expect(glyph.codepoint != 0);
                }
            }
        }
    }

    try std.testing.expectEqual(metrics, [3]i64{ atlas.cellWidth(), atlas.lineHeight(), atlas.ascender() });
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
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 32 });
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
    try std.testing.expectEqual(Id.symbols, atlas.fonts.source(icon));
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
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").nerd_symbols, .pixel_height = 16 });
    defer atlas.deinit();
    try std.testing.expectEqual(Id.text, atlas.fonts.source("A"));
    try std.testing.expectEqual(Id.primary, atlas.fonts.source("\u{f07b}"));
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
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 32 });
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    var run: TextRun = .{ .text = "A\u{f07b}\u{f02db}e\u{301}", .x = 5, .y = 36, .color = .white, .pixel_height = 32 };
    const width: f32 = @floatFromInt(atlas.cellWidth());
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
