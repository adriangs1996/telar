//! Owns one FreeType/HarfBuzz face and its optional macOS optical rasterizer.
const std = @import("std");
const freetype = @import("freetype");
const AtlasOptions = @import("AtlasOptions.zig");
const MacRasterizer = @import("MacRasterizer.zig");
const FontFace = @This();

face: freetype.c.FT_Face,
shaping_font: *freetype.c.hb_font_t,
mac_rasterizer: ?MacRasterizer,

/// Borrows font bytes and the shared alpha page until deinit.
/// Example: `var face = try FontFace.init(library, options, pixels);`
pub fn init(library: freetype.c.FT_Library, options: AtlasOptions, pixels: []u8) !FontFace {
    var face: freetype.c.FT_Face = undefined;
    if (freetype.c.FT_New_Memory_Face(library, @ptrCast(options.font.ptr), @intCast(options.font.len), @max(0, options.face_index), &face) != 0) {
        return error.FontInitFailed;
    }
    errdefer _ = freetype.c.FT_Done_Face(face);
    if (options.face_index < 0 and options.postscript.len != 0) {
        const count = face.*.num_faces;
        if (count > 256) {
            return error.FontCollectionTooLarge;
        }

        var index: freetype.c.FT_Long = 0;
        while (true) {
            const name = freetype.c.FT_Get_Postscript_Name(face);
            if (name != null and std.mem.eql(u8, std.mem.span(name), options.postscript)) {
                break;
            }
            index += 1;
            if (index == count) {
                return error.FontFaceNotFound;
            }

            var candidate: freetype.c.FT_Face = undefined;
            if (freetype.c.FT_New_Memory_Face(library, @ptrCast(options.font.ptr), @intCast(options.font.len), index, &candidate) != 0) {
                return error.FontInitFailed;
            }
            _ = freetype.c.FT_Done_Face(face);
            face = candidate;
        }
    }
    if (freetype.c.FT_Select_Charmap(face, freetype.c.FT_ENCODING_UNICODE) != 0) {
        return error.UnicodeCharmapUnavailable;
    }
    const shaping_font = freetype.c.hb_ft_font_create_referenced(face) orelse return error.ShapingFontInitFailed;
    errdefer freetype.c.hb_font_destroy(shaping_font);
    var mac_rasterizer: ?MacRasterizer = null;
    if (@import("builtin").os.tag == .macos and options.thicken) {
        mac_rasterizer = try MacRasterizer.init(.{
            .font = options.font.ptr,
            .font_len = options.font.len,
            .postscript = @ptrCast(freetype.c.FT_Get_Postscript_Name(face)),
            .face_index = @intCast(face.*.face_index),
            .pixels = pixels.ptr,
            .side = @intCast(std.math.sqrt(pixels.len)),
            .strength = options.thicken_strength,
        });
    }
    errdefer if (mac_rasterizer) |*rasterizer| {
        rasterizer.deinit();
    };

    return .{ .face = face, .shaping_font = shaping_font, .mac_rasterizer = mac_rasterizer };
}

pub fn deinit(font: *FontFace) void {
    if (font.mac_rasterizer) |*rasterizer| {
        rasterizer.deinit();
    }

    freetype.c.hb_font_destroy(font.shaping_font);
    _ = freetype.c.FT_Done_Face(font.face);
}

/// Sizes this face while leaving the primary font's grid authoritative.
/// Example: `try face.select(28);`
pub fn select(font: *FontFace, pixel_height: u16) !void {
    if (freetype.c.FT_Set_Pixel_Sizes(font.face, 0, pixel_height) != 0) {
        return error.FontSizeFailed;
    }

    if (font.mac_rasterizer) |*rasterizer| {
        try rasterizer.select(pixel_height);
    }

    freetype.c.hb_ft_font_changed(font.shaping_font);
}

/// Tests the whole grapheme so combining marks never switch faces mid-cluster.
/// Example: `if (face.covers("e\u{301}")) { ... }`
pub fn covers(font: *const FontFace, text: []const u8) bool {
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == 0x200c or codepoint == 0x200d or
            (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
            (codepoint >= 0xe0100 and codepoint <= 0xe01ef))
        {
            continue;
        }

        if (freetype.c.FT_Get_Char_Index(font.face, codepoint) == 0) {
            return false;
        }
    }

    return true;
}
