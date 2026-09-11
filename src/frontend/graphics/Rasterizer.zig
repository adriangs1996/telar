const freetype = @import("freetype");
const rasterizer_support = @import("rasterizer_support.zig");
const Metrics = @import("Metrics.zig");
const TextDraw = @import("TextDraw.zig");
const ShapedText = @import("ShapedText.zig");
const std = @import("std");
const Rasterizer = @This();

library: freetype.c.FT_Library,
face: freetype.c.FT_Face,
shaping_font: *freetype.c.hb_font_t,
shaping_buffer: *freetype.c.hb_buffer_t,
pixel_height: u16 = 0,

pub fn init() !Rasterizer {
    return initFont(rasterizer_support.embedded_font);
}

/// `font` must outlive the rasterizer because FreeType keeps a borrowed
/// pointer to memory-backed faces.
pub fn initFont(font: []const u8) !Rasterizer {
    var library: freetype.c.FT_Library = undefined;
    if (freetype.c.FT_Init_FreeType(&library) != 0) {
        return error.FreeTypeInitFailed;
    }
    errdefer _ = freetype.c.FT_Done_FreeType(library);

    var face: freetype.c.FT_Face = undefined;
    if (freetype.c.FT_New_Memory_Face(
        library,
        @ptrCast(font.ptr),
        @intCast(font.len),
        0,
        &face,
    ) != 0) {
        return error.FontInitFailed;
    }
    errdefer _ = freetype.c.FT_Done_Face(face);
    if (freetype.c.FT_Select_Charmap(face, freetype.c.FT_ENCODING_UNICODE) != 0) {
        return error.UnicodeCharmapUnavailable;
    }

    const shaping_font = freetype.c.hb_ft_font_create_referenced(face) orelse
        return error.ShapingFontInitFailed;
    errdefer freetype.c.hb_font_destroy(shaping_font);
    const shaping_buffer = freetype.c.hb_buffer_create() orelse
        return error.ShapingBufferInitFailed;
    errdefer freetype.c.hb_buffer_destroy(shaping_buffer);

    return .{
        .library = library,
        .face = face,
        .shaping_font = shaping_font,
        .shaping_buffer = shaping_buffer,
    };
}

pub fn deinit(rasterizer: *Rasterizer) void {
    freetype.c.hb_buffer_destroy(rasterizer.shaping_buffer);
    freetype.c.hb_font_destroy(rasterizer.shaping_font);
    _ = freetype.c.FT_Done_Face(rasterizer.face);
    _ = freetype.c.FT_Done_FreeType(rasterizer.library);
    rasterizer.* = undefined;
}

pub fn setPixelHeight(rasterizer: *Rasterizer, pixel_height: u16) !void {
    if (pixel_height == 0) {
        return error.InvalidPixelHeight;
    }
    if (rasterizer.pixel_height == pixel_height) {
        return;
    }
    if (freetype.c.FT_Set_Pixel_Sizes(rasterizer.face, 0, pixel_height) != 0) {
        return error.FontSizeFailed;
    }
    freetype.c.hb_ft_font_changed(rasterizer.shaping_font);
    rasterizer.pixel_height = pixel_height;
}

pub fn metrics(rasterizer: *const Rasterizer) Metrics {
    const raw = rasterizer.face.*.size.*.metrics;
    return .{
        .ascender = rasterizer_support.fixed26_6Round(raw.ascender),
        .descender = rasterizer_support.fixed26_6Round(raw.descender),
        .line_height = @intCast(@max(1, rasterizer_support.fixed26_6Round(raw.height))),
    };
}

/// Measures the same shaped advances used by drawText, without painting.
/// Example: `const width = try rasterizer.measureText("1 nvim");`.
pub fn measureText(rasterizer: *Rasterizer, text: []const u8) !u32 {
    if (rasterizer.pixel_height == 0) {
        return error.FontSizeNotSet;
    }
    if (text.len == 0) {
        return 0;
    }

    const shaped = try rasterizer.shapeText(text);
    var advance: i64 = 0;
    for (shaped.glyphs, shaped.positions) |glyph, position| {
        if (glyph.codepoint == 0) {
            return error.MissingGlyph;
        }

        advance += position.x_advance;
    }

    return @intCast(@max(0, rasterizer_support.fixed26_6Round(advance)));
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
        if (rasterizer_support.fixed26_6Round(next_x - origin_fixed) > draw.max_width) {
            break;
        }
        if (freetype.c.FT_Load_Glyph(rasterizer.face, glyph.codepoint, freetype.c.FT_LOAD_DEFAULT) != 0) {
            return error.GlyphLoadFailed;
        }
        const slot = rasterizer.face.*.glyph;
        if (freetype.c.FT_Render_Glyph(slot, freetype.c.FT_RENDER_MODE_NORMAL) != 0) {
            return error.GlyphRenderFailed;
        }

        try rasterizer_support.blendBitmap(.{
            .surface = draw.surface,
            .bitmap = slot.*.bitmap,
            .destination = .{
                .x = rasterizer_support.fixed26_6Round(pen_x + position.x_offset) + slot.*.bitmap_left,
                .y = draw.origin.y - rasterizer_support.fixed26_6Round(position.y_offset) - slot.*.bitmap_top,
            },
            .color = draw.color,
        });
        pen_x = next_x;
    }
    return @intCast(@max(0, rasterizer_support.fixed26_6Round(pen_x - origin_fixed)));
}

pub fn shapeText(rasterizer: *Rasterizer, text: []const u8) !ShapedText {
    if (!std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidUtf8;
    }
    freetype.c.hb_buffer_reset(rasterizer.shaping_buffer);
    freetype.c.hb_buffer_add_utf8(
        rasterizer.shaping_buffer,
        text.ptr,
        @intCast(text.len),
        0,
        @intCast(text.len),
    );
    if (freetype.c.hb_buffer_allocation_successful(rasterizer.shaping_buffer) == 0) {
        return error.ShapingFailed;
    }
    freetype.c.hb_buffer_guess_segment_properties(rasterizer.shaping_buffer);
    freetype.c.hb_shape(rasterizer.shaping_font, rasterizer.shaping_buffer, null, 0);
    var glyph_count: c_uint = 0;
    const glyphs = freetype.c.hb_buffer_get_glyph_infos(
        rasterizer.shaping_buffer,
        &glyph_count,
    ) orelse return error.ShapingFailed;
    var position_count: c_uint = 0;
    const positions = freetype.c.hb_buffer_get_glyph_positions(
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
