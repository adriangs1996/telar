//! Rasterizes glyphs on demand into one alpha page the GPU samples, and
//! turns shaped text into quads. One page serves every size the client
//! paints at, so a frame samples one texture. Texel (0, 0) stays opaque white
//! so solid rectangles are quads too. Shaping mirrors the TUI rasterizer; sharing one
//! face between adapters is a later step.
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
face: freetype.c.FT_Face,
shaping_font: *freetype.c.hb_font_t,
shaping_buffer: *freetype.c.hb_buffer_t,
pixel_height: u16 = 0,
shaping_cache: ShapingCache,
shape_calls: usize = 0,
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

    var face: freetype.c.FT_Face = undefined;
    if (freetype.c.FT_New_Memory_Face(library, @ptrCast(options.font.ptr), @intCast(options.font.len), 0, &face) != 0) {
        return error.FontInitFailed;
    }
    errdefer _ = freetype.c.FT_Done_Face(face);
    if (freetype.c.FT_Select_Charmap(face, freetype.c.FT_ENCODING_UNICODE) != 0) {
        return error.UnicodeCharmapUnavailable;
    }
    const shaping_font = freetype.c.hb_ft_font_create_referenced(face) orelse return error.ShapingFontInitFailed;
    errdefer freetype.c.hb_font_destroy(shaping_font);
    const shaping_buffer = freetype.c.hb_buffer_create() orelse return error.ShapingBufferInitFailed;
    errdefer freetype.c.hb_buffer_destroy(shaping_buffer);

    var shaping_cache = try ShapingCache.init(allocator);
    errdefer shaping_cache.deinit(allocator);
    var atlas: GlyphAtlas = .{
        .allocator = allocator,
        .pixels = pixels,
        .library = library,
        .face = face,
        .shaping_font = shaping_font,
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

    if (freetype.c.FT_Set_Pixel_Sizes(atlas.face, 0, pixel_height) != 0) {
        return error.FontSizeFailed;
    }

    freetype.c.hb_ft_font_changed(atlas.shaping_font);
    atlas.pixel_height = pixel_height;
    atlas.shaping_cache.clear();
}

pub fn deinit(atlas: *GlyphAtlas) void {
    atlas.shaping_cache.deinit(atlas.allocator);
    atlas.glyphs.deinit(atlas.allocator);
    freetype.c.hb_buffer_destroy(atlas.shaping_buffer);
    freetype.c.hb_font_destroy(atlas.shaping_font);
    _ = freetype.c.FT_Done_Face(atlas.face);
    _ = freetype.c.FT_Done_FreeType(atlas.library);
    atlas.allocator.free(atlas.pixels);
    atlas.* = undefined;
}

/// Distance from the baseline up to the top of the tallest glyph at the
/// selected size, in pixels.
pub fn ascender(atlas: *const GlyphAtlas) i32 {
    return round26(atlas.face.*.size.*.metrics.ascender);
}

/// Measures the monospace grid. Example: `const width = atlas.cellWidth();`
pub fn cellWidth(atlas: *const GlyphAtlas) u16 {
    return @intCast(@max(1, round26(atlas.face.*.size.*.metrics.max_advance)));
}

pub fn lineHeight(atlas: *const GlyphAtlas) u32 {
    return @intCast(@max(1, round26(atlas.face.*.size.*.metrics.height)));
}

/// Shapes one line, rasterizes glyphs the page lacks and appends a quad per
/// visible glyph. Returns the pen advance in pixels.
/// Example: `const advance = try atlas.place(.{ .text = "Telar", .x = 32, .y = 64, .color = ink }, &list);`
pub fn place(atlas: *GlyphAtlas, run: TextRun, list: *QuadList) !f32 {
    if (run.text.len == 0) {
        return 0;
    }

    try atlas.select(run.pixel_height);
    const shaped = try atlas.shape(run.text);
    const origin: i64 = @intFromFloat(@round(run.x * 64));
    var pen_x = origin;
    for (shaped.glyphs, shaped.positions) |info, position| {
        const placed = atlas.slot(info.codepoint, run) catch |err| switch (err) {
            error.AtlasFull => try atlas.slot(0, run),
            else => return err,
        };
        if (placed.width > 0 and placed.height > 0) {
            const x = round26(pen_x + position.x_offset) + placed.left;
            const y: i32 = @as(i32, @intFromFloat(@round(run.y))) - round26(position.y_offset) - placed.top;
            try list.push(.{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
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

        pen_x += position.x_advance;
    }

    return @floatFromInt(round26(pen_x - origin));
}

fn slot(atlas: *GlyphAtlas, index: u32, run: TextRun) !GlyphSlot {
    const key = (@as(u64, index) << 18) | (@as(u64, atlas.pixel_height) << 2) | @as(u64, @intFromBool(run.bold)) | (@as(u64, @intFromBool(run.italic)) << 1);
    if (atlas.glyphs.get(key)) |cached| {
        return cached;
    }

    if (freetype.c.FT_Load_Glyph(atlas.face, index, freetype.c.FT_LOAD_DEFAULT) != 0) {
        return error.GlyphLoadFailed;
    }

    const glyph = atlas.face.*.glyph;
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

    const origin = try atlas.pack(.{ bitmap.width, bitmap.rows });
    if (bitmap.buffer) |buffer| {
        const pitch: usize = @intCast(@abs(bitmap.pitch));
        for (0..bitmap.rows) |row| {
            const source = buffer[row * pitch ..][0..bitmap.width];
            const destination = atlas.pixels[(origin[1] + row) * side + origin[0] ..][0..bitmap.width];
            @memcpy(destination, source);
        }

        atlas.version +%= 1;
    }

    const scale: f32 = 1.0 / @as(f32, @floatFromInt(side));
    const placed: GlyphSlot = .{
        .u0 = @as(f32, @floatFromInt(origin[0])) * scale,
        .v0 = @as(f32, @floatFromInt(origin[1])) * scale,
        .u1 = @as(f32, @floatFromInt(origin[0] + bitmap.width)) * scale,
        .v1 = @as(f32, @floatFromInt(origin[1] + bitmap.rows)) * scale,
        .width = bitmap.width,
        .height = bitmap.rows,
        .left = glyph.*.bitmap_left,
        .top = glyph.*.bitmap_top,
    };
    try atlas.glyphs.put(atlas.allocator, key, placed);
    return placed;
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

fn shape(atlas: *GlyphAtlas, text: []const u8) !ShapedRun {
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
    freetype.c.hb_shape(atlas.shaping_font, atlas.shaping_buffer, null, 0);
    var glyph_count: c_uint = 0;
    const glyphs = freetype.c.hb_buffer_get_glyph_infos(atlas.shaping_buffer, &glyph_count) orelse return error.ShapingFailed;
    var position_count: c_uint = 0;
    const positions = freetype.c.hb_buffer_get_glyph_positions(atlas.shaping_buffer, &position_count) orelse return error.ShapingFailed;
    if (position_count != glyph_count) {
        return error.ShapingFailed;
    }

    const shaped: ShapedRun = .{ .glyphs = glyphs[0..glyph_count], .positions = positions[0..glyph_count] };
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

/// Reserves fallback glyphs before terminal output fills the atlas.
/// Example: `try atlas.prepareFallbacks();`
pub fn prepareFallbacks(atlas: *GlyphAtlas) !void {
    for (0..4) |style| {
        _ = try atlas.slot(0, .{ .text = "", .x = 0, .y = 0, .color = .white, .pixel_height = atlas.pixel_height, .bold = style & 1 != 0, .italic = style & 2 != 0 });
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
