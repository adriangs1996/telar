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
sans: FontFace,
sans_semibold: FontFace,

/// Loads the configured face plus embedded text, symbols and the two chrome
/// sans weights, sharing one page.
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
    var symbols = try FontFace.init(library, fallback, pixels);
    errdefer symbols.deinit();
    fallback.font = assets.plex_sans;
    var sans = try FontFace.init(library, fallback, pixels);
    errdefer sans.deinit();
    fallback.font = assets.plex_sans_semibold;
    const sans_semibold = try FontFace.init(library, fallback, pixels);
    return .{ .primary = primary, .text = text, .symbols = symbols, .sans = sans, .sans_semibold = sans_semibold };
}

pub fn deinit(fonts: *FontSet) void {
    fonts.sans_semibold.deinit();
    fonts.sans.deinit();
    fonts.symbols.deinit();
    if (fonts.text) |*face| {
        face.deinit();
    }

    fonts.primary.deinit();
}

/// Prefers the requested face whenever it covers the whole grapheme, then the
/// terminal chain: configured font, embedded text font, symbols.
/// Example: `const id = fonts.source("\u{f07b}", .sans);`
pub fn source(fonts: *const FontSet, text: []const u8, preferred: Id) Id {
    if (preferred != .primary and fonts.borrow(preferred).covers(text)) {
        return preferred;
    }

    if (fonts.primary.covers(text)) {
        return .primary;
    }

    if (fonts.text) |*face_value| {
        if (face_value.covers(text)) {
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
        .sans => &fonts.sans,
        .sans_semibold => &fonts.sans_semibold,
    };
}

fn borrow(fonts: *const FontSet, id: Id) *const FontFace {
    return switch (id) {
        .primary => &fonts.primary,
        .text => &fonts.text.?,
        .symbols => &fonts.symbols,
        .sans => &fonts.sans,
        .sans_semibold => &fonts.sans_semibold,
    };
}
