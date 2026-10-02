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

test "a run shaped across cells splits by cluster and compares glyphs without clusters" {
    const Info = freetype.c.hb_glyph_info_t;
    const Position = freetype.c.hb_glyph_position_t;
    var glyphs = [_]Info{ std.mem.zeroes(Info), std.mem.zeroes(Info), std.mem.zeroes(Info) };
    var positions = [_]Position{ std.mem.zeroes(Position), std.mem.zeroes(Position), std.mem.zeroes(Position) };
    // A spacer for the first cell, a ligature with a mark for the second.
    for (&glyphs, [_]u32{ 7, 9, 11 }, [_]u32{ 0, 1, 1 }) |*glyph, index, cluster| {
        glyph.codepoint = index;
        glyph.cluster = cluster;
    }

    positions[2].x_offset = -64;
    const run: ShapedRun = .{ .font = .primary, .columns = 2, .glyphs = &glyphs, .positions = &positions };
    try std.testing.expect(run.ordered());
    const first = run.split(1);
    try std.testing.expectEqual(@as(usize, 1), first[0].glyphs.len);
    const second = first[1].split(2);
    try std.testing.expectEqual(@as(usize, 2), second[0].glyphs.len);
    try std.testing.expectEqual(@as(usize, 0), second[1].glyphs.len);
    try std.testing.expectEqual(@as(u32, 11), second[0].glyphs[1].codepoint);

    // The same glyphs from other clusters compare equal; an offset does not.
    var moved = glyphs;
    for (&moved) |*glyph| {
        glyph.cluster += 4;
    }

    var other = run;
    other.glyphs = &moved;
    try std.testing.expect(run.sameGlyphs(other));
    try std.testing.expectEqual(run.glyphHash(), other.glyphHash());
    var shifted = positions;
    shifted[2].x_offset = 0;
    other.positions = &shifted;
    try std.testing.expect(!run.sameGlyphs(other));
    try std.testing.expect(run.glyphHash() != other.glyphHash());
    try std.testing.expect(empty.glyphHash() != 0);

    moved[0].cluster = 9;
    other.positions = &positions;
    try std.testing.expect(!other.ordered());
    other = run;
    other.rtl = true;
    try std.testing.expect(!other.ordered());
}
