//! Which codepoints a face's ligature lookups substitute or read as context
//! across neighbouring graphemes, and how far that context reaches. Read
//! once from the face's GSUB table and OS/2 `usMaxContext` when the font
//! set opens; a face without such lookups covers nothing, so its cells keep
//! shaping alone and the terminal grid draws exactly what it drew before.
const std = @import("std");
const freetype = @import("freetype");
const assets = @import("assets");
const LigatureRole = @import("LigatureRole.zig").LigatureRole;
const cellgrid = @import("cellgrid");
const LigatureCoverage = @This();

const c = freetype.c;

/// The default GSUB features whose lookups can join neighbouring graphemes:
/// standard, contextual and required ligatures and contextual alternates.
/// HarfBuzz applies them with no feature list; `ccmp` and `locl` act within
/// one grapheme and stay out.
const features = [_][4]u8{ "liga".*, "clig".*, "calt".*, "rlig".*, "rclt".* };
const gsub_tag = tag("GSUB".*);
/// The first OS/2 table version that carries `usMaxContext`.
const max_context_version = 2;
/// The version FreeType reports for a face without an OS/2 table.
const missing_version = 0xffff;
const ascii_count = 128;

ascii: [ascii_count]LigatureRole = @splat(.none),
/// Codepoints a lookup substitutes; null when the face has none.
input: ?*c.hb_set_t = null,
/// Codepoints a lookup only reads around the glyphs it substitutes.
context: ?*c.hb_set_t = null,
/// The longest glyph sequence one lookup reads, from OS/2 `usMaxContext`;
/// zero when the face does not declare it.
reach: u16 = 0,

/// Reads the face's GSUB lookups through HarfBuzz, which follows nested
/// and class-based rules. Allocates its sets once, outside painting.
/// Example: `var coverage = try LigatureCoverage.init(face.face, face.shaping_font);`
pub fn init(face: c.FT_Face, font: *c.hb_font_t) !LigatureCoverage {
    const layout = c.hb_font_get_face(font);
    var tags: [features.len + 1]c.hb_tag_t = undefined;
    for (features, 0..) |feature, index| {
        tags[index] = tag(feature);
    }

    tags[features.len] = 0;
    const lookups = try createSet();
    defer c.hb_set_destroy(lookups);
    c.hb_ot_layout_collect_lookups(layout, gsub_tag, null, null, &tags, lookups);
    if (c.hb_set_is_empty(lookups) != 0) {
        return .{};
    }

    const input_glyphs = try createSet();
    defer c.hb_set_destroy(input_glyphs);
    const context_glyphs = try createSet();
    defer c.hb_set_destroy(context_glyphs);
    var lookup: c.hb_codepoint_t = std.math.maxInt(c.hb_codepoint_t);
    while (c.hb_set_next(lookups, &lookup) != 0) {
        c.hb_ot_layout_lookup_collect_glyphs(layout, gsub_tag, lookup, context_glyphs, input_glyphs, context_glyphs, null);
    }

    const glyphs = c.hb_map_create() orelse return error.OutOfMemory;
    defer c.hb_map_destroy(glyphs);
    const unicodes = try createSet();
    defer c.hb_set_destroy(unicodes);
    c.hb_face_collect_nominal_glyph_mapping(layout, glyphs, unicodes);
    const input = try createSet();
    errdefer c.hb_set_destroy(input);
    const context = try createSet();
    errdefer c.hb_set_destroy(context);
    var ascii: [ascii_count]LigatureRole = @splat(.none);
    var codepoint: c.hb_codepoint_t = std.math.maxInt(c.hb_codepoint_t);
    while (c.hb_set_next(unicodes, &codepoint) != 0) {
        const glyph = c.hb_map_get(glyphs, codepoint);
        const found: LigatureRole = if (c.hb_set_has(input_glyphs, glyph) != 0) .input else if (c.hb_set_has(context_glyphs, glyph) != 0) .context else .none;
        switch (found) {
            .none => continue,
            .input => c.hb_set_add(input, codepoint),
            .context => c.hb_set_add(context, codepoint),
        }

        if (codepoint < ascii_count) {
            ascii[codepoint] = found;
        }
    }

    for ([_]*c.hb_set_t{ input_glyphs, context_glyphs, input, context }) |set| {
        if (c.hb_set_allocation_successful(set) == 0) {
            return error.OutOfMemory;
        }
    }

    if (c.hb_set_is_empty(input) != 0) {
        c.hb_set_destroy(input);
        c.hb_set_destroy(context);
        return .{};
    }

    return .{
        .ascii = ascii,
        .input = input,
        .context = context,
        .reach = maxContext(face),
    };
}

pub fn deinit(self: *LigatureCoverage) void {
    if (self.input) |set| {
        c.hb_set_destroy(set);
    }

    if (self.context) |set| {
        c.hb_set_destroy(set);
    }

    self.* = .{};
}

/// Whether any codepoint of the face can join a ligature; a face that
/// joins none keeps every cell shaping alone.
/// Example: `if (!coverage.joins()) return drawAlone();`
pub fn joins(self: *const LigatureCoverage) bool {
    return self.input != null;
}

/// Whether any cell of a row holds a codepoint a lookup may substitute: a
/// row without one shapes cell by cell. ASCII reads a table; any other
/// cluster counts as possible, and splitting the row decides.
/// Example: `if (!coverage.substitutes(row)) return paintAlone(row);`
pub fn substitutes(self: *const LigatureCoverage, cells: []const cellgrid.Cell) bool {
    for (cells) |*cell| {
        if (cell.len != 1 or cell.bytes[0] >= ascii_count or self.ascii[cell.bytes[0]] == .input) {
            return true;
        }
    }

    return false;
}

/// The strongest role of a grapheme's codepoints, or `.none` when any of
/// them takes no part, so a cluster joins a run only when the face shapes
/// all of it. ASCII reads a table; other text probes the sets.
/// Example: `if (coverage.role(cell.text()) == .input) { ... }`
pub fn role(self: *const LigatureCoverage, text: []const u8) LigatureRole {
    if (text.len == 1 and text[0] < ascii_count) {
        return self.ascii[text[0]];
    }

    const input = self.input orelse return .none;
    const context = self.context.?;
    const view = std.unicode.Utf8View.init(text) catch return .none;
    var iterator = view.iterator();
    var strongest: LigatureRole = .none;
    while (iterator.nextCodepoint()) |codepoint| {
        const current: LigatureRole = if (c.hb_set_has(input, codepoint) != 0) .input else if (c.hb_set_has(context, codepoint) != 0) .context else return .none;
        if (@intFromEnum(current) > @intFromEnum(strongest)) {
            strongest = current;
        }
    }

    return strongest;
}

fn createSet() !*c.hb_set_t {
    const set = c.hb_set_create() orelse return error.OutOfMemory;
    if (c.hb_set_allocation_successful(set) == 0) {
        c.hb_set_destroy(set);
        return error.OutOfMemory;
    }

    return set;
}

fn tag(name: [4]u8) c.hb_tag_t {
    return std.mem.readInt(u32, &name, .big);
}

// OS/2 `usMaxContext` exists from table version 2 on; older or missing
// tables declare no reach.
fn maxContext(face: c.FT_Face) u16 {
    const table = c.FT_Get_Sfnt_Table(face, c.FT_SFNT_OS2) orelse return 0;
    const os2: *const c.TT_OS2 = @ptrCast(@alignCast(table));
    if (os2.version == missing_version or os2.version < max_context_version) {
        return 0;
    }

    return os2.usMaxContext;
}

test "coverage reads which codepoints each face's ligature lookups substitute or read" {
    var library: c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_Init_FreeType(&library));
    defer _ = c.FT_Done_FreeType(library);
    const Expected = struct { font: []const u8, joins: bool, input: []const u8 = "", context: []const u8 = "", none: []const u8 = "" };
    const faces = [_]Expected{
        // Programming ligatures through `calt`: operators substitute, digits,
        // capitals and spaces only steer them, lowercase never takes part.
        .{ .font = assets.jetbrains_mono, .joins = true, .input = "-=>!|&:/*<", .context = " 019AZ", .none = "abxyz,\"\u{e9}\u{301}" },
        // A symbols face has no ligature lookups at all.
        .{ .font = assets.nerd_symbols, .joins = false, .none = "->=\u{f07b}" },
        // A proportional face whose only ligature is the typographic `fi`.
        .{ .font = assets.plex_sans, .joins = true, .input = "fi", .none = "->= " },
    };
    for (faces) |expected| {
        var face: c.FT_Face = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.FT_New_Memory_Face(library, expected.font.ptr, @intCast(expected.font.len), 0, &face));
        defer _ = c.FT_Done_Face(face);
        const font = c.hb_ft_font_create_referenced(face).?;
        defer c.hb_font_destroy(font);
        var coverage = try init(face, font);
        defer coverage.deinit();
        try std.testing.expectEqual(expected.joins, coverage.joins());
        for (expected.input) |byte| {
            try std.testing.expectEqual(LigatureRole.input, coverage.role(&.{byte}));
        }

        for (expected.context) |byte| {
            try std.testing.expectEqual(LigatureRole.context, coverage.role(&.{byte}));
        }

        var graphemes = std.unicode.Utf8View.initUnchecked(expected.none).iterator();
        while (graphemes.nextCodepointSlice()) |grapheme| {
            try std.testing.expectEqual(LigatureRole.none, coverage.role(grapheme));
        }
    }

    // A cluster joins only when the face shapes all of it.
    var face: c.FT_Face = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.FT_New_Memory_Face(library, assets.jetbrains_mono.ptr, @intCast(assets.jetbrains_mono.len), 0, &face));
    defer _ = c.FT_Done_Face(face);
    const font = c.hb_ft_font_create_referenced(face).?;
    defer c.hb_font_destroy(font);
    var coverage = try init(face, font);
    defer coverage.deinit();
    try std.testing.expectEqual(@as(u16, 6), coverage.reach);
    try std.testing.expectEqual(LigatureRole.none, coverage.role("=\u{301}"));
    try std.testing.expectEqual(LigatureRole.none, coverage.role("\xff"));
    try std.testing.expectEqual(LigatureRole.none, coverage.role(""));
}
