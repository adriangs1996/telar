//! Which cells of one row segment the primary face shapes together, so its
//! ligatures and contextual alternates see their neighbours. Runs break
//! where Ghostty's `font/shaper/run.zig` breaks them: at the row's ends, at
//! a change of ink style (backgrounds may differ), at the cursor, at wide
//! and spacer cells, and before a typographic `fi`, `fl` or `st`. They also
//! break at cells the face's ligature lookups never read, and they drop
//! cells farther than the face's declared context reach from every
//! codepoint a lookup substitutes, since no rule can see past it; the run
//! that remains shapes exactly as the whole segment would. A run longer
//! than `max_cells` shapes cell by cell instead, never cut into pieces that
//! could form ligatures the whole would not. Columns are reserved with the
//! grid, so splitting a row allocates nothing.
const std = @import("std");
const cellgrid = @import("cellgrid");
const cellglyphs = @import("cellglyphs");
const assets = @import("assets");
const freetype = @import("freetype");
const LigatureCoverage = @import("../text/LigatureCoverage.zig");
const LigatureRole = @import("../text/LigatureRole.zig").LigatureRole;
const CellRun = @import("CellRun.zig");
const RowRuns = @This();

/// The longest run shaped together; its text fits `max_cells` full cells.
pub const max_cells = 128;
pub const max_bytes = max_cells * cellgrid.Cell.max_bytes;
/// The most glyphs a run keeps; a run its face expands past this shapes
/// cell by cell.
pub const max_glyphs = 2 * max_cells;

const far = std.math.maxInt(u16);

const Column = struct {
    role: LigatureRole,
    /// Shapes with the column before it, if both are kept.
    joins: bool,
    /// Within the context reach of a substituted codepoint.
    kept: bool,
    /// Columns since the last substituted codepoint of its segment.
    since: u16,
};

allocator: std.mem.Allocator,
columns: std.ArrayList(Column) = .empty,
previous: cellgrid.Cell = .{},
/// Cells of the segment a lookup substitutes; none leaves every cell alone.
inputs: u16 = 0,

pub fn init(allocator: std.mem.Allocator) RowRuns {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *RowRuns) void {
    self.columns.deinit(self.allocator);
}

/// Reserves one column per grid column; steady frames allocate nothing.
/// Example: `try runs.reserve(cols);`
pub fn reserve(self: *RowRuns, cols: u16) !void {
    try self.columns.ensureTotalCapacityPrecise(self.allocator, cols);
}

/// Starts a row segment. Example: `runs.clear();`
pub fn clear(self: *RowRuns) void {
    self.columns.clearRetainingCapacity();
    self.inputs = 0;
}

/// Adds the next cell as the renderer paints it, with selection already
/// projected into its style. `alone` keeps the cell out of every run: the
/// cursor shows the character under it, not the ligature it belongs to.
/// Example: `runs.append(coverage, cell, col == cursor);`
pub fn append(self: *RowRuns, coverage: *const LigatureCoverage, cell: *const cellgrid.Cell, alone: bool) void {
    const role: LigatureRole = if (alone or !shapeable(cell)) .none else coverage.role(cell.text());
    const count = self.columns.items.len;
    const joins = role != .none and count > 0 and self.columns.items[count - 1].role != .none and
        sameInk(self.previous.style, cell.style) and !typographic(&self.previous, cell);
    self.columns.appendAssumeCapacity(.{
        .role = role,
        .joins = joins,
        .kept = false,
        .since = far,
    });
    self.previous = cell.*;
    self.inputs += @intFromBool(role == .input);
}

/// Keeps the cells within `reach` of a substituted codepoint of their
/// segment; a reach of zero, undeclared, keeps every joined cell.
/// Example: `runs.close(coverage.reach);`
pub fn close(self: *RowRuns, reach: u16) void {
    if (self.inputs == 0) {
        return;
    }

    const limit: u16 = if (reach == 0 or reach > max_cells) max_cells else reach;
    var since: u16 = far;
    for (self.columns.items) |*column| {
        if (!column.joins) {
            since = far;
        }

        since = if (column.role == .input) 0 else if (since == far) far else since + 1;
        column.since = since;
    }

    var until: u16 = far;
    var index = self.columns.items.len;
    while (index > 0) {
        index -= 1;
        const column = &self.columns.items[index];
        until = if (column.role == .input) 0 else if (until == far) far else until + 1;
        column.kept = column.role != .none and @min(column.since, until) < limit;
        if (!column.joins) {
            until = far;
        }
    }
}

/// The run that starts at `start`. Example: `const run = runs.at(col); col += run.len;`
pub fn at(self: *const RowRuns, start: u16) CellRun {
    const columns = self.columns.items;
    if (!columns[start].kept) {
        return .{
            .len = 1,
            .together = false,
        };
    }

    var end: usize = start + 1;
    while (end < columns.len and columns[end].kept and columns[end].joins) {
        end += 1;
    }

    const len: u16 = @intCast(end - start);
    return .{
        .len = len,
        .together = len > 1 and len <= max_cells,
    };
}

// Wide characters and their spacers keep their own cells, invisible cells
// draw nothing, and procedural characters are drawn from geometry.
fn shapeable(cell: *const cellgrid.Cell) bool {
    if (cell.width != 1 or cell.style.flags.invisible) {
        return false;
    }

    const text = cell.text();
    if (text.len == 1) {
        return true;
    }

    return cellglyphs.Braille.parse(text) == null and cellglyphs.BoxDrawing.parse(text) == null and cellglyphs.BlockElement.parse(text) == null;
}

// One glyph takes one color and one synthetic style: cells join only when
// their glyph ink matches. Backgrounds stay per cell, as in Ghostty, inverse
// swaps which color the glyph takes, and lines drawn over the cell (under,
// over and strikethrough) never change a glyph, so a hovered or underlined
// span keeps its ligatures.
fn sameInk(left: cellgrid.Style, right: cellgrid.Style) bool {
    return inkStyle(left).eql(inkStyle(right));
}

fn inkStyle(style: cellgrid.Style) cellgrid.Style {
    var ink = style;
    if (style.flags.inverse) {
        ink.fg = .default;
    } else {
        ink.bg = .default;
    }

    ink.underline_color = .default;
    ink.flags.underline = .none;
    ink.flags.overline = false;
    ink.flags.strikethrough = false;
    return ink;
}

// Ghostty splits these pairs because typographic ligatures read as one
// letter in a monospace grid; programming ligatures keep their cells.
fn typographic(left: *const cellgrid.Cell, right: *const cellgrid.Cell) bool {
    if (left.len != 1 or right.len != 1) {
        return false;
    }

    return switch (left.bytes[0]) {
        'f' => right.bytes[0] == 'i' or right.bytes[0] == 'l',
        's' => right.bytes[0] == 't',
        else => false,
    };
}

test "runs keep context within the face's reach and split at style, cursor and wide cells" {
    var library: freetype.c.FT_Library = undefined;
    try std.testing.expectEqual(@as(c_int, 0), freetype.c.FT_Init_FreeType(&library));
    defer _ = freetype.c.FT_Done_FreeType(library);
    var face: freetype.c.FT_Face = undefined;
    try std.testing.expectEqual(@as(c_int, 0), freetype.c.FT_New_Memory_Face(library, assets.jetbrains_mono.ptr, @intCast(assets.jetbrains_mono.len), 0, &face));
    defer _ = freetype.c.FT_Done_Face(face);
    const font = freetype.c.hb_ft_font_create_referenced(face).?;
    defer freetype.c.hb_font_destroy(font);
    var coverage = try LigatureCoverage.init(face, font);
    defer coverage.deinit();
    try std.testing.expect(coverage.joins());
    try std.testing.expectEqual(@as(u16, 6), coverage.reach);

    var runs = RowRuns.init(std.testing.allocator);
    defer runs.deinit();
    try runs.reserve(40);
    const Case = struct { text: []const u8, cursor: ?usize = null, bold: ?usize = null, runs: []const CellRun };
    const alone: CellRun = .{ .len = 1, .together = false };
    const cases = [_]Case{
        // Letters split; spaces and digits ride along within reach.
        .{ .text = "a -> b", .runs = &.{ alone, .{ .len = 4, .together = true }, alone } },
        // Blanks past the reach shape alone.
        .{ .text = "x=1;" ++ " " ** 10, .runs = &.{ alone, .{ .len = 8, .together = true }, alone, alone, alone, alone, alone } },
        // A run of context alone has nothing to substitute.
        .{ .text = "AB 12", .runs = &.{ alone, alone, alone, alone, alone } },
        // The cursor shows the character under it.
        .{ .text = "->", .cursor = 1, .runs = &.{ alone, alone } },
        // Ink style splits; a lone input cell shapes alone.
        .{ .text = "!=", .bold = 1, .runs = &.{ alone, alone } },
    };
    for (cases) |case| {
        runs.clear();
        for (case.text, 0..) |byte, index| {
            var cell: cellgrid.Cell = .{};
            cell.bytes[0] = byte;
            cell.style.flags.bold = case.bold == index;
            runs.append(&coverage, &cell, case.cursor == index);
        }

        runs.close(coverage.reach);
        var col: u16 = 0;
        for (case.runs) |expected| {
            try std.testing.expectEqual(expected, runs.at(col));
            col += expected.len;
        }

        try std.testing.expectEqual(@as(usize, col), case.text.len);
    }
}
