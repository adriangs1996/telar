const freetype = @import("freetype");
const rasterizer_support = @import("rasterizer_support.zig");
const Metrics = @import("Metrics.zig");
const Surface = @import("Surface.zig");
const RasterizerPoint = @import("RasterizerPoint.zig");
const Color = @import("Color.zig");
const std = @import("std");
const Rasterizer = @This();

library: freetype.c.FT_Library,
face: freetype.c.FT_Face,
shaping_font: *freetype.c.hb_font_t,
shaping_buffer: *freetype.c.hb_buffer_t,
pixel_height: u16 = 0,

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

pub fn deinit(self: *Rasterizer) void {
    freetype.c.hb_buffer_destroy(self.shaping_buffer);
    freetype.c.hb_font_destroy(self.shaping_font);
    _ = freetype.c.FT_Done_Face(self.face);
    _ = freetype.c.FT_Done_FreeType(self.library);
    self.* = undefined;
}

pub fn setPixelHeight(self: *Rasterizer, pixel_height: u16) !void {
    if (pixel_height == 0) {
        return error.InvalidPixelHeight;
    }
    if (self.pixel_height == pixel_height) {
        return;
    }
    if (freetype.c.FT_Set_Pixel_Sizes(self.face, 0, pixel_height) != 0) {
        return error.FontSizeFailed;
    }
    freetype.c.hb_ft_font_changed(self.shaping_font);
    self.pixel_height = pixel_height;
}

pub fn metrics(self: *const Rasterizer) Metrics {
    const raw = self.face.*.size.*.metrics;
    return .{
        .ascender = rasterizer_support.fixed26_6Round(raw.ascender),
        .descender = rasterizer_support.fixed26_6Round(raw.descender),
        .line_height = @intCast(@max(1, rasterizer_support.fixed26_6Round(raw.height))),
    };
}

/// Measures the same shaped advances used by drawText, without painting.
/// Example: `const width = try rasterizer.measureText("1 nvim");`.
pub fn measureText(self: *Rasterizer, text: []const u8) !u32 {
    if (self.pixel_height == 0) {
        return error.FontSizeNotSet;
    }
    if (text.len == 0) {
        return 0;
    }

    const shaped = try self.shapeText(text);
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
pub fn drawText(self: *Rasterizer, draw: TextDraw) !u32 {
    try draw.surface.validate();
    if (self.pixel_height == 0) {
        return error.FontSizeNotSet;
    }
    if (draw.text.len == 0) {
        return 0;
    }
    const shaped = try self.shapeText(draw.text);

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
        if (freetype.c.FT_Load_Glyph(self.face, glyph.codepoint, freetype.c.FT_LOAD_DEFAULT) != 0) {
            return error.GlyphLoadFailed;
        }
        const slot = self.face.*.glyph;
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

pub fn shapeText(self: *Rasterizer, text: []const u8) !ShapedText {
    if (!std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidUtf8;
    }
    freetype.c.hb_buffer_reset(self.shaping_buffer);
    freetype.c.hb_buffer_add_utf8(
        self.shaping_buffer,
        text.ptr,
        @intCast(text.len),
        0,
        @intCast(text.len),
    );
    if (freetype.c.hb_buffer_allocation_successful(self.shaping_buffer) == 0) {
        return error.ShapingFailed;
    }
    freetype.c.hb_buffer_guess_segment_properties(self.shaping_buffer);
    freetype.c.hb_shape(self.shaping_font, self.shaping_buffer, null, 0);
    var glyph_count: c_uint = 0;
    const glyphs = freetype.c.hb_buffer_get_glyph_infos(
        self.shaping_buffer,
        &glyph_count,
    ) orelse return error.ShapingFailed;
    var position_count: c_uint = 0;
    const positions = freetype.c.hb_buffer_get_glyph_positions(
        self.shaping_buffer,
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

const ShapedText = struct {
    glyphs: []const freetype.c.hb_glyph_info_t,
    positions: []const freetype.c.hb_glyph_position_t,
};

const TextDraw = struct {
    surface: Surface,
    origin: RasterizerPoint,
    text: []const u8,
    color: Color,
    max_width: u32,
};
