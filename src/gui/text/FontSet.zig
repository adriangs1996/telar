//! Fixed fallback order; no installed-font discovery occurs while painting.
const std = @import("std");
const freetype = @import("freetype");
const assets = @import("assets");
const FontFace = @import("FontFace.zig");
const AtlasOptions = @import("AtlasOptions.zig");
const Id = @import("font_id.zig").Id;
const FontSet = @This();

primary: FontFace,
text: ?FontFace,
symbols: FontFace,

/// Loads the configured face plus embedded text and symbols, sharing one page.
/// Example: `var fonts = try FontSet.init(library, options, pixels);`
pub fn init(library: freetype.c.FT_Library, options: AtlasOptions, pixels: []u8) !FontSet {
    var primary = try FontFace.init(library, options, pixels);
    errdefer primary.deinit();
    var fallback = options;
    fallback.face_index = 0;
    fallback.postscript = "";
    fallback.font = assets.jetbrains_mono;
    var text: ?FontFace = if (std.mem.eql(u8, options.font, assets.jetbrains_mono)) null else try FontFace.init(library, fallback, pixels);
    errdefer if (text) |*face| {
        face.deinit();
    };
    fallback.font = assets.nerd_symbols;
    const symbols = try FontFace.init(library, fallback, pixels);
    return .{ .primary = primary, .text = text, .symbols = symbols };
}

pub fn deinit(fonts: *FontSet) void {
    fonts.symbols.deinit();
    if (fonts.text) |*face| {
        face.deinit();
    }

    fonts.primary.deinit();
}

/// Resizes all faces without changing their identities in the glyph cache.
/// Example: `try fonts.select(28);`
pub fn select(fonts: *FontSet, pixel_height: u16) !void {
    try fonts.primary.select(pixel_height);
    if (fonts.text) |*face| {
        try face.select(pixel_height);
    }

    try fonts.symbols.select(pixel_height);
}

/// Preserves the configured face wherever it covers the complete grapheme.
/// Example: `const id = fonts.source("\u{f07b}");`
pub fn source(fonts: *const FontSet, text: []const u8) Id {
    if (fonts.primary.covers(text)) {
        return .primary;
    }

    if (fonts.text) |*face| {
        if (face.covers(text)) {
            return .text;
        }
    }

    return if (fonts.symbols.covers(text)) .symbols else .primary;
}

pub fn get(fonts: *FontSet, id: Id) *FontFace {
    return switch (id) {
        .primary => &fonts.primary,
        .text => &fonts.text.?,
        .symbols => &fonts.symbols,
    };
}
