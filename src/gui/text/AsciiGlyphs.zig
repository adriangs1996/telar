//! Resolved glyphs for one-byte ASCII runs in the primary face at the
//! atlas height, indexed by byte and style. Terminal cells are almost all
//! such runs; a hit skips the procedural parsers, the shaping cache and the
//! glyph map. Atlas slots never move, so an entry stays valid until the font
//! set changes, which clears the table with the shaping cache.
const AsciiGlyph = @import("AsciiGlyph.zig");
const TextRun = @import("TextRun.zig");
const Glyphs = @This();

const styles = 4;

entries: [128 * styles]?AsciiGlyph = @splat(null),

/// The table index for a cacheable run, or null. Example: `const index = Glyphs.index(run, atlas.pixel_height) orelse return;`
pub fn index(run: TextRun, pixel_height: u16) ?usize {
    if (run.text.len != 1 or run.text[0] >= 128 or run.face != .primary or run.pixel_height != pixel_height) {
        return null;
    }

    return @as(usize, run.text[0]) * styles + @intFromBool(run.bold) + 2 * @as(usize, @intFromBool(run.italic));
}

/// Example: `if (glyphs.find(index)) |glyph| paint(glyph);`
pub fn find(self: *const Glyphs, entry: usize) ?AsciiGlyph {
    return self.entries[entry];
}

/// Example: `glyphs.remember(index, glyph);`
pub fn remember(self: *Glyphs, entry: usize, glyph: AsciiGlyph) void {
    self.entries[entry] = glyph;
}

/// Example: `glyphs.clear();`
pub fn clear(self: *Glyphs) void {
    self.entries = @splat(null);
}
