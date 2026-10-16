//! Owns one FreeType/HarfBuzz face, its optional macOS optical rasterizer
//! and a bounded set of sized instances, so chrome labels at several
//! heights and terminal cells share the face without re-running its size
//! setup or invalidating anything cached per height.
const builtin = @import("builtin");
const std = @import("std");
const freetype = @import("freetype");
const AtlasOptions = @import("AtlasOptions.zig");
const MacRasterizer = @import("MacRasterizer.zig");
const FontSize = @import("FontSize.zig");
const FontVariation = @import("../native/FontVariation.zig").FontVariation;
const FontFace = @This();

extern fn FT_New_Size(freetype.c.FT_Face, *freetype.c.FT_Size) freetype.c.FT_Error;
extern fn FT_Done_Size(freetype.c.FT_Size) freetype.c.FT_Error;
extern fn FT_Activate_Size(freetype.c.FT_Size) freetype.c.FT_Error;

/// Pixel heights one face keeps sized at once: the terminal cell, the three
/// chrome roles and room for a size change in flight. More is an error, not
/// an eviction, so a sized instance never disappears under a cached run.
pub const max_sizes = 8;

/// 1.0 in FreeType's 16.16 fixed point, which design coordinates use.
const fixed_one = 65536.0;

face: freetype.c.FT_Face,
shaping_font: *freetype.c.hb_font_t,
mac_rasterizer: ?MacRasterizer,
sizes: [max_sizes]?FontSize = @splat(null),
/// The pixel height FreeType loads and HarfBuzz shapes with; zero before
/// the first selection.
active: u16 = 0,

/// Borrows font bytes and the shared alpha page until deinit.
/// Example: `var face = try FontFace.init(library, options, pixels);`
pub fn init(library: freetype.c.FT_Library, options: AtlasOptions, pixels: []u8) !FontFace {
    // SAFETY: FT_New_Memory_Face writes face on success; failure returns before reading the face or registering cleanup.
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

            // SAFETY: FT_New_Memory_Face writes candidate on success; failure returns before replacing face.
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

    // The rasterizer finds the face by its default PostScript name, which
    // FreeType renames once a variation applies, so it opens first.
    var mac_rasterizer: ?MacRasterizer = null;
    if (builtin.os.tag == .macos and options.thicken) {
        mac_rasterizer = try MacRasterizer.init(.{
            .font = options.font.ptr,
            .font_len = options.font.len,
            .postscript = @ptrCast(freetype.c.FT_Get_Postscript_Name(face)),
            .face_index = @intCast(face.*.face_index),
            .pixels = pixels.ptr,
            .side = @intCast(std.math.sqrt(pixels.len)),
            .strength = options.thicken_strength,
            .variation = &options.variation,
        });
    }
    errdefer if (mac_rasterizer) |*rasterizer| {
        rasterizer.deinit();
    };

    try vary(library, face, &options.variation);

    // HarfBuzz reads the face's variation coordinates when it is created.
    const shaping_font = freetype.c.hb_ft_font_create_referenced(face) orelse return error.ShapingFontInitFailed;
    return .{ .face = face, .shaping_font = shaping_font, .mac_rasterizer = mac_rasterizer };
}

/// Moves a variable face to the requested design coordinates; every other
/// axis keeps its default. A tag the face lacks or a value outside its axis
/// range is refused rather than clamped into a different instance.
fn vary(library: freetype.c.FT_Library, face: freetype.c.FT_Face, variation: *const FontVariation) !void {
    if (variation.count == 0) {
        return;
    }

    if (variation.count > FontVariation.max_axes) {
        return error.FontVariationTooLarge;
    }

    var master: [*c]freetype.c.FT_MM_Var = null;
    if (freetype.c.FT_Get_MM_Var(face, &master) != 0) {
        return error.FontVariationUnavailable;
    }
    defer _ = freetype.c.FT_Done_MM_Var(library, master);

    const axes = master.*.axis[0..master.*.num_axis];
    if (axes.len > FontVariation.max_axes) {
        return error.FontVariationTooLarge;
    }

    // SAFETY: the loop below writes every coordinate FreeType reads, one per axis.
    var coordinates: [FontVariation.max_axes]freetype.c.FT_Fixed = undefined;
    for (axes, 0..) |axis, index| {
        coordinates[index] = axis.def;
    }

    for (variation.tags[0..variation.count], variation.values[0..variation.count]) |tag, requested| {
        const index = for (axes, 0..) |axis, position| {
            if (axis.tag == tag) {
                break position;
            }
        } else return error.FontVariationAxisMissing;

        const fixed = @as(f64, requested) * fixed_one;
        if (!std.math.isFinite(fixed) or fixed < @as(f64, @floatFromInt(axes[index].minimum)) or fixed > @as(f64, @floatFromInt(axes[index].maximum))) {
            return error.FontVariationOutOfRange;
        }

        coordinates[index] = @intFromFloat(@round(fixed));
    }

    if (freetype.c.FT_Set_Var_Design_Coordinates(face, @intCast(axes.len), &coordinates) != 0) {
        return error.FontVariationFailed;
    }
}

pub fn deinit(self: *FontFace) void {
    if (self.mac_rasterizer) |*rasterizer| {
        rasterizer.deinit();
    }

    freetype.c.hb_font_destroy(self.shaping_font);
    _ = freetype.c.FT_Done_Face(self.face);
}

/// Makes `pixel_height` the size glyph loading and shaping use. A height
/// seen before reuses its `FT_Size`; switching between resident heights
/// only activates one and refreshes the HarfBuzz scale.
/// Example: `try face.select(28);`
pub fn select(self: *FontFace, pixel_height: u16) !void {
    if (self.active == pixel_height) {
        return;
    }

    const size = try self.sized(pixel_height);
    if (FT_Activate_Size(size.handle) != 0) {
        return error.FontSizeFailed;
    }

    self.active = pixel_height;
    freetype.c.hb_ft_font_changed(self.shaping_font);
}

/// The sized instance for `pixel_height`, created on first use without
/// changing the active size, so metrics of any resident height are
/// readable while another is selected.
/// Example: `const line = (try face.sized(13)).lineHeight();`
pub fn sized(self: *FontFace, pixel_height: u16) !FontSize {
    if (pixel_height == 0) {
        return error.InvalidPixelHeight;
    }

    if (self.find(pixel_height)) |size| {
        return size;
    }

    const slot = self.emptySlot() orelse return error.TooManyFontSizes;
    // SAFETY: FT_New_Size writes handle on success; failure returns before activation or cleanup registration.
    var handle: freetype.c.FT_Size = undefined;
    if (FT_New_Size(self.face, &handle) != 0) {
        return error.FontSizeFailed;
    }
    errdefer _ = FT_Done_Size(handle);

    // Pixel sizes apply to the active size; restore the previous one after.
    if (FT_Activate_Size(handle) != 0 or freetype.c.FT_Set_Pixel_Sizes(self.face, 0, pixel_height) != 0) {
        return error.FontSizeFailed;
    }

    if (self.find(self.active)) |previous| {
        if (FT_Activate_Size(previous.handle) != 0) {
            return error.FontSizeFailed;
        }
    }

    const size: FontSize = .{ .pixel_height = pixel_height, .handle = handle };
    slot.* = size;
    return size;
}

fn find(self: *const FontFace, pixel_height: u16) ?FontSize {
    for (self.sizes) |slot| {
        if (slot) |size| {
            if (size.pixel_height == pixel_height) {
                return size;
            }
        }
    }

    return null;
}

fn emptySlot(self: *FontFace) ?*?FontSize {
    for (&self.sizes) |*slot| {
        if (slot.* == null) {
            return slot;
        }
    }

    return null;
}

/// True for an outline face without color glyph tables: the only kind the
/// alpha page can hold. Example: `if (!face.monochrome()) { ... }`
pub fn monochrome(self: *const FontFace) bool {
    const flags = self.face.*.face_flags;
    return flags & freetype.c.FT_FACE_FLAG_SCALABLE != 0 and flags & freetype.c.FT_FACE_FLAG_COLOR == 0;
}

/// Tests the whole grapheme so combining marks never switch faces mid-cluster.
/// Example: `if (face.covers("e\u{301}")) { ... }`
pub fn covers(self: *const FontFace, text: []const u8) bool {
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == 0x200c or codepoint == 0x200d or
            (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
            (codepoint >= 0xe0100 and codepoint <= 0xe01ef))
        {
            continue;
        }

        if (freetype.c.FT_Get_Char_Index(self.face, codepoint) == 0) {
            return false;
        }
    }

    return true;
}
