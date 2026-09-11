const Rasterizer = @This();
const ft = @import("freetype").c;
const source_namespace = @import("rasterizer_support.zig");
const Metrics = @import("Metrics.zig");
const TextDraw = @import("TextDraw.zig");
const std = @import("std");
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
    return initFont(source_namespace.embedded_font);
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
        .ascender = source_namespace.fixed26_6Round(raw.ascender),
        .descender = source_namespace.fixed26_6Round(raw.descender),
        .line_height = @intCast(@max(1, source_namespace.fixed26_6Round(raw.height))),
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

    return @intCast(@max(0, source_namespace.fixed26_6Round(advance)));
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
        if (source_namespace.fixed26_6Round(next_x - origin_fixed) > draw.max_width) {
            break;
        }
        if (ft.FT_Load_Glyph(rasterizer.face, glyph.codepoint, ft.FT_LOAD_DEFAULT) != 0) {
            return error.GlyphLoadFailed;
        }
        const slot = rasterizer.face.*.glyph;
        if (ft.FT_Render_Glyph(slot, ft.FT_RENDER_MODE_NORMAL) != 0) {
            return error.GlyphRenderFailed;
        }

        try source_namespace.blendBitmap(.{
            .surface = draw.surface,
            .bitmap = slot.*.bitmap,
            .destination = .{
                .x = source_namespace.fixed26_6Round(pen_x + position.x_offset) + slot.*.bitmap_left,
                .y = draw.origin.y - source_namespace.fixed26_6Round(position.y_offset) - slot.*.bitmap_top,
            },
            .color = draw.color,
        });
        pen_x = next_x;
    }
    return @intCast(@max(0, source_namespace.fixed26_6Round(pen_x - origin_fixed)));
}

pub fn shapeText(rasterizer: *Rasterizer, text: []const u8) !ShapedText {
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
