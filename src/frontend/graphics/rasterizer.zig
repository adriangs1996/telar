//! Reusable client-side text rasterization backed by embedded JetBrains Mono.
//!
//! The rasterizer owns FreeType's mutable face and is therefore intentionally
//! single-threaded. Callers own the destination buffer and the media-path
//! scheduling around it.

const std = @import("std");
const ft = @import("freetype").c;

pub const embedded_font: []const u8 = @embedFile("../assets/JetBrainsMono-Regular.ttf");

pub const Color = struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8 = 255,
};

pub const Surface = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    pub fn validate(surface: Surface) !void {
        const pixel_count = std.math.mul(usize, surface.width, surface.height) catch
            return error.SurfaceTooLarge;
        const byte_count = std.math.mul(usize, pixel_count, 4) catch
            return error.SurfaceTooLarge;
        if (surface.pixels.len != byte_count) {
            return error.InvalidSurface;
        }
    }
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const TextDraw = struct {
    surface: Surface,
    origin: Point,
    text: []const u8,
    color: Color,
    max_width: u32,
};

const BitmapBlend = struct {
    surface: Surface,
    bitmap: ft.FT_Bitmap,
    destination: Point,
    color: Color,
};

const PixelBlend = struct {
    point: struct { x: u32, y: u32 },
    color: Color,
    alpha: u8,
};

pub const Metrics = struct {
    ascender: i32,
    descender: i32,
    line_height: u32,
};

pub const Rasterizer = struct {
    const ShapedText = struct {
        glyphs: []const ft.hb_glyph_info_t,
        positions: []const ft.hb_glyph_position_t,
    };

    library: ft.FT_Library,
    face: ft.FT_Face,
    shaping_font: *ft.hb_font_t,
    shaping_buffer: *ft.hb_buffer_t,
    pixel_height: u16 = 0,

    pub fn init() !Rasterizer {
        return initFont(embedded_font);
    }

    /// `font` must outlive the rasterizer because FreeType keeps a borrowed
    /// pointer to memory-backed faces.
    pub fn initFont(font: []const u8) !Rasterizer {
        var library: ft.FT_Library = undefined;
        if (ft.FT_Init_FreeType(&library) != 0) {
            return error.FreeTypeInitFailed;
        }
        errdefer _ = ft.FT_Done_FreeType(library);

        var face: ft.FT_Face = undefined;
        if (ft.FT_New_Memory_Face(
            library,
            @ptrCast(font.ptr),
            @intCast(font.len),
            0,
            &face,
        ) != 0) {
            return error.FontInitFailed;
        }
        errdefer _ = ft.FT_Done_Face(face);
        if (ft.FT_Select_Charmap(face, ft.FT_ENCODING_UNICODE) != 0) {
            return error.UnicodeCharmapUnavailable;
        }

        const shaping_font = ft.hb_ft_font_create_referenced(face) orelse
            return error.ShapingFontInitFailed;
        errdefer ft.hb_font_destroy(shaping_font);
        const shaping_buffer = ft.hb_buffer_create() orelse
            return error.ShapingBufferInitFailed;
        errdefer ft.hb_buffer_destroy(shaping_buffer);

        return .{
            .library = library,
            .face = face,
            .shaping_font = shaping_font,
            .shaping_buffer = shaping_buffer,
        };
    }

    pub fn deinit(rasterizer: *Rasterizer) void {
        ft.hb_buffer_destroy(rasterizer.shaping_buffer);
        ft.hb_font_destroy(rasterizer.shaping_font);
        _ = ft.FT_Done_Face(rasterizer.face);
        _ = ft.FT_Done_FreeType(rasterizer.library);
        rasterizer.* = undefined;
    }

    pub fn setPixelHeight(rasterizer: *Rasterizer, pixel_height: u16) !void {
        if (pixel_height == 0) {
            return error.InvalidPixelHeight;
        }
        if (rasterizer.pixel_height == pixel_height) {
            return;
        }
        if (ft.FT_Set_Pixel_Sizes(rasterizer.face, 0, pixel_height) != 0) {
            return error.FontSizeFailed;
        }
        ft.hb_ft_font_changed(rasterizer.shaping_font);
        rasterizer.pixel_height = pixel_height;
    }

    pub fn metrics(rasterizer: *const Rasterizer) Metrics {
        const raw = rasterizer.face.*.size.*.metrics;
        return .{
            .ascender = fixed26_6Round(raw.ascender),
            .descender = fixed26_6Round(raw.descender),
            .line_height = @intCast(@max(1, fixed26_6Round(raw.height))),
        };
    }

    /// Draws one UTF-8 line and returns its pixel advance. The baseline and
    /// origin are signed so bearings may safely extend outside the surface.
    /// For example: `try rasterizer.drawText(.{ .surface = surface, .origin = .{ .x = 0, .y = 16 }, .text = "Telar", .color = color, .max_width = 80 })`.
    pub fn drawText(rasterizer: *Rasterizer, draw: TextDraw) !u32 {
        try draw.surface.validate();
        if (rasterizer.pixel_height == 0) {
            return error.FontSizeNotSet;
        }
        if (draw.text.len == 0) {
            return 0;
        }
        const shaped = try rasterizer.shapeText(draw.text);

        var pen_x = draw.origin.x * 64;
        const origin_fixed = pen_x;
        for (shaped.glyphs, shaped.positions) |glyph, position| {
            if (glyph.codepoint == 0) {
                return error.MissingGlyph;
            }
            const next_x = pen_x + position.x_advance;
            if (fixed26_6Round(next_x - origin_fixed) > draw.max_width) {
                break;
            }
            if (ft.FT_Load_Glyph(rasterizer.face, glyph.codepoint, ft.FT_LOAD_DEFAULT) != 0) {
                return error.GlyphLoadFailed;
            }
            const slot = rasterizer.face.*.glyph;
            if (ft.FT_Render_Glyph(slot, ft.FT_RENDER_MODE_NORMAL) != 0) {
                return error.GlyphRenderFailed;
            }

            try blendBitmap(.{
                .surface = draw.surface,
                .bitmap = slot.*.bitmap,
                .destination = .{
                    .x = fixed26_6Round(pen_x + position.x_offset) + slot.*.bitmap_left,
                    .y = draw.origin.y - fixed26_6Round(position.y_offset) - slot.*.bitmap_top,
                },
                .color = draw.color,
            });
            pen_x = next_x;
        }
        return @intCast(@max(0, fixed26_6Round(pen_x - origin_fixed)));
    }

    fn shapeText(rasterizer: *Rasterizer, text: []const u8) !ShapedText {
        if (!std.unicode.utf8ValidateSlice(text)) {
            return error.InvalidUtf8;
        }
        ft.hb_buffer_reset(rasterizer.shaping_buffer);
        ft.hb_buffer_add_utf8(
            rasterizer.shaping_buffer,
            text.ptr,
            @intCast(text.len),
            0,
            @intCast(text.len),
        );
        if (ft.hb_buffer_allocation_successful(rasterizer.shaping_buffer) == 0) {
            return error.ShapingFailed;
        }
        ft.hb_buffer_guess_segment_properties(rasterizer.shaping_buffer);
        ft.hb_shape(rasterizer.shaping_font, rasterizer.shaping_buffer, null, 0);
        var glyph_count: c_uint = 0;
        const glyphs = ft.hb_buffer_get_glyph_infos(
            rasterizer.shaping_buffer,
            &glyph_count,
        ) orelse return error.ShapingFailed;
        var position_count: c_uint = 0;
        const positions = ft.hb_buffer_get_glyph_positions(
            rasterizer.shaping_buffer,
            &position_count,
        ) orelse return error.ShapingFailed;
        if (position_count != glyph_count) {
            return error.ShapingFailed;
        }
        return .{
            .glyphs = glyphs[0..glyph_count],
            .positions = positions[0..glyph_count],
        };
    }
};

fn fixed26_6Round(value: anytype) i32 {
    const signed: i64 = @intCast(value);
    return @intCast(if (signed >= 0) (signed + 32) >> 6 else -(((-signed) + 32) >> 6));
}

fn blendBitmap(blend: BitmapBlend) !void {
    if (blend.bitmap.pixel_mode != ft.FT_PIXEL_MODE_GRAY and
        blend.bitmap.pixel_mode != ft.FT_PIXEL_MODE_MONO)
    {
        return error.UnsupportedPixelMode;
    }
    if (blend.bitmap.buffer == null) {
        return;
    }
    const rows: usize = @intCast(blend.bitmap.rows);
    const columns: usize = @intCast(blend.bitmap.width);
    const pitch: i32 = blend.bitmap.pitch;
    const absolute_pitch: usize = @intCast(@abs(pitch));
    const source = blend.bitmap.buffer[0 .. absolute_pitch * rows];

    for (0..rows) |source_y| {
        const target_y = blend.destination.y + @as(i32, @intCast(source_y));
        if (target_y < 0 or target_y >= blend.surface.height) {
            continue;
        }
        const physical_y = if (pitch >= 0) source_y else rows - 1 - source_y;
        const source_row = source[physical_y * absolute_pitch ..][0..absolute_pitch];
        for (0..columns) |source_x| {
            const target_x = blend.destination.x + @as(i32, @intCast(source_x));
            if (target_x < 0 or target_x >= blend.surface.width) {
                continue;
            }
            const coverage: u8 = if (blend.bitmap.pixel_mode == ft.FT_PIXEL_MODE_GRAY)
                source_row[source_x]
            else if (source_row[source_x / 8] & (@as(u8, 0x80) >> @intCast(source_x % 8)) != 0)
                255
            else
                0;
            if (coverage == 0) {
                continue;
            }
            const alpha: u8 = @intCast((@as(u16, coverage) * blend.color.alpha + 127) / 255);
            blendPixel(blend.surface, .{
                .point = .{ .x = @intCast(target_x), .y = @intCast(target_y) },
                .color = blend.color,
                .alpha = alpha,
            });
        }
    }
}

fn blendPixel(surface: Surface, blend: PixelBlend) void {
    const index = (@as(usize, blend.point.y) * surface.width + blend.point.x) * 4;
    const inverse: u16 = 255 - blend.alpha;
    const previous_alpha = surface.pixels[index + 3];
    surface.pixels[index] = compositeChannel(surface.pixels[index], blend.color.red, blend.alpha);
    surface.pixels[index + 1] = compositeChannel(surface.pixels[index + 1], blend.color.green, blend.alpha);
    surface.pixels[index + 2] = compositeChannel(surface.pixels[index + 2], blend.color.blue, blend.alpha);
    surface.pixels[index + 3] = @intCast(@min(
        255,
        @as(u16, blend.alpha) + (@as(u16, previous_alpha) * inverse + 127) / 255,
    ));
}

fn compositeChannel(previous: u8, next: u8, alpha: u8) u8 {
    const inverse: u16 = 255 - alpha;
    return @intCast((@as(u16, next) * alpha + @as(u16, previous) * inverse + 127) / 255);
}

test "embedded JetBrains Mono rasterizes UTF-8 into RGBA" {
    var rasterizer = try Rasterizer.init();
    defer rasterizer.deinit();
    try rasterizer.setPixelHeight(16);

    var pixels: [256 * 32 * 4]u8 = @splat(0);
    const surface: Surface = .{ .pixels = &pixels, .width = 256, .height = 32 };
    const advance = try rasterizer.drawText(.{
        .surface = surface,
        .origin = .{ .x = 4, .y = 22 },
        .text = "Telar ✓",
        .color = .{ .red = 220, .green = 230, .blue = 240 },
        .max_width = 248,
    });
    try std.testing.expect(advance > 0);
    try std.testing.expect(std.mem.indexOfNone(u8, &pixels, &.{0}) != null);
}

test "HarfBuzz shapes a decomposed grapheme before rasterization" {
    var rasterizer = try Rasterizer.init();
    defer rasterizer.deinit();
    try rasterizer.setPixelHeight(16);
    const shaped = try rasterizer.shapeText("e\u{301}");
    try std.testing.expectEqual(@as(usize, 1), shaped.glyphs.len);
}

test "empty notification lines are valid" {
    var rasterizer = try Rasterizer.init();
    defer rasterizer.deinit();
    try rasterizer.setPixelHeight(16);
    var pixels: [4]u8 = @splat(0);
    try std.testing.expectEqual(@as(u32, 0), try rasterizer.drawText(.{
        .surface = .{ .pixels = &pixels, .width = 1, .height = 1 },
        .origin = .{ .x = 0, .y = 0 },
        .text = "",
        .color = .{ .red = 255, .green = 255, .blue = 255 },
        .max_width = 1,
    }));
}

test "surface length is checked before rasterization" {
    var rasterizer = try Rasterizer.init();
    defer rasterizer.deinit();
    try rasterizer.setPixelHeight(12);
    var pixels: [3]u8 = @splat(0);
    try std.testing.expectError(error.InvalidSurface, rasterizer.drawText(.{
        .surface = .{ .pixels = &pixels, .width = 1, .height = 1 },
        .origin = .{ .x = 0, .y = 0 },
        .text = "x",
        .color = .{ .red = 255, .green = 255, .blue = 255 },
        .max_width = 1,
    }));
}
