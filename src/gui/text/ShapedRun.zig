//! One shaped face span, borrowed from HarfBuzz or the bounded shaping cache.
const std = @import("std");
const font_id = @import("font_id.zig");
const freetype = @import("freetype");
const ShapedRun = @This();

/// No glyphs: what a run shapes into when the grid keeps its cells apart.
pub const empty: ShapedRun = .{
    .font = .primary,
    .columns = 0,
    .glyphs = &.{},
    .positions = &.{},
};

font: font_id.Id,
columns: u32,
glyphs: []const freetype.c.hb_glyph_info_t,
positions: []const freetype.c.hb_glyph_position_t,
rtl: bool = false,

/// Splits a run shaped across cells, whose clusters never decrease, before
/// its first glyph whose cluster starts at or after byte `end`: the head is
/// one cell's share, pen-relative from its own first glyph, so each cell
/// stays on the grid however the face advances. A ligature that merged
/// several cells keeps its earliest cluster and lands in the first of them.
/// Example: `const parts = rest.split(cell_end); paint(parts[0]); rest = parts[1];`
pub fn split(self: ShapedRun, end: u32) [2]ShapedRun {
    var count: usize = 0;
    while (count < self.glyphs.len and self.glyphs[count].cluster < end) {
        count += 1;
    }

    var head = self;
    head.glyphs = self.glyphs[0..count];
    head.positions = self.positions[0..count];
    var tail = self;
    tail.glyphs = self.glyphs[count..];
    tail.positions = self.positions[count..];
    return .{ head, tail };
}

/// Whether glyph clusters never decrease, as a left-to-right run of cells
/// needs to hand each cell its own glyphs.
/// Example: `if (!shaped.ordered()) return paintAlone();`
pub fn ordered(self: ShapedRun) bool {
    if (self.rtl) {
        return false;
    }

    if (self.glyphs.len < 2) {
        return true;
    }

    for (self.glyphs[1..], 0..) |glyph, index| {
        if (glyph.cluster < self.glyphs[index].cluster) {
            return false;
        }
    }

    return true;
}

/// Whether two runs draw the same glyphs at the same pen offsets, whatever
/// text clusters they came from.
/// Example: `if (share.sameGlyphs(alone)) paintAlone();`
pub fn sameGlyphs(self: ShapedRun, other: ShapedRun) bool {
    if (self.font != other.font or self.glyphs.len != other.glyphs.len) {
        return false;
    }

    for (self.glyphs, other.glyphs, self.positions, other.positions) |left, right, left_position, right_position| {
        if (left.codepoint != right.codepoint or !samePosition(left_position, right_position)) {
            return false;
        }
    }

    return true;
}

/// A nonzero identity of the glyphs and pen offsets a cell draws, so a
/// retained cell repaints exactly when its share of a run changes.
/// Example: `key.context = share.glyphHash();`
pub fn glyphHash(self: ShapedRun) u64 {
    var hasher = std.hash.Wyhash.init(@intFromEnum(self.font));
    for (self.glyphs, self.positions) |glyph, position| {
        const fields = [_]i32{ position.x_advance, position.y_advance, position.x_offset, position.y_offset };
        hasher.update(std.mem.asBytes(&glyph.codepoint));
        hasher.update(std.mem.asBytes(&fields));
    }

    return @max(1, hasher.final());
}

// HarfBuzz keeps private state beside the public fields; only these place a glyph.
fn samePosition(left: freetype.c.hb_glyph_position_t, right: freetype.c.hb_glyph_position_t) bool {
    return left.x_advance == right.x_advance and left.y_advance == right.y_advance and left.x_offset == right.x_offset and left.y_offset == right.y_offset;
}
