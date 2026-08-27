//! The grid to draw into.
//!
//! Knows nothing about the terminal, which is what makes every widget testable:
//! draw into a buffer, then assert on cells. A widget is not a type here - it
//! is `fn (buf: *Buffer, area: Rect, ...) void`, and that is the whole
//! extension mechanism.

const std = @import("std");
const Rect = @import("geometry.zig").Rect;
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;
const Style = cell_mod.Style;
const text_mod = @import("text.zig");
const measure = text_mod.measure;
const GraphemeIterator = text_mod.GraphemeIterator;

pub const Buffer = struct {
    cells: []Cell,
    w: u16,
    h: u16,
    gpa: std.mem.Allocator,

    /// Nothing is written outside this. Starts as the whole buffer.
    clip: Rect,
    stack: [max_clip_depth]Rect = undefined,
    depth: u8 = 0,

    /// Base, a pane, a dropdown, a modal, a tooltip inside it. More nesting
    /// than this is a layout that has lost track of itself.
    pub const max_clip_depth = 8;

    pub fn init(gpa: std.mem.Allocator, w: u16, h: u16) !Buffer {
        const cells = try gpa.alloc(Cell, @as(usize, w) * @as(usize, h));
        @memset(cells, .{});
        return .{
            .cells = cells,
            .w = w,
            .h = h,
            .gpa = gpa,
            .clip = .{ .w = w, .h = h },
        };
    }

    /// Restricts drawing to the overlap of `r` and the current clip.
    ///
    /// This is what makes a widget unable to damage its neighbours. Passing a
    /// rectangle to a draw function is a *request*; the clip is the part the
    /// widget cannot argue with, which matters most for the things that do not
    /// take a rectangle at all - a pane blit, a long label, a box border.
    ///
    /// Silently ignored past `max_clip_depth`, because the alternative is a
    /// draw path that can fail, and a frame that draws one widget unclipped is
    /// a cosmetic bug where a frame that returns an error is a blank screen.
    pub fn pushClip(b: *Buffer, r: Rect) void {
        if (b.depth == max_clip_depth) return;
        b.stack[b.depth] = b.clip;
        b.depth += 1;
        b.clip = b.clip.intersect(r);
    }

    pub fn popClip(b: *Buffer) void {
        if (b.depth == 0) return;
        b.depth -= 1;
        b.clip = b.stack[b.depth];
    }

    pub fn deinit(b: *Buffer) void {
        b.gpa.free(b.cells);
    }

    pub fn resize(b: *Buffer, w: u16, h: u16) !void {
        // Fresh allocation rather than realloc: the old cells are cleared
        // below anyway, so copying them into the new block is wasted work.
        const cells = try b.gpa.alloc(Cell, @as(usize, w) * @as(usize, h));
        b.gpa.free(b.cells);
        b.cells = cells;
        b.w = w;
        b.h = h;
        // The clip described a buffer that no longer exists, and a stale one
        // would silently drop everything drawn outside the old bounds.
        b.clip = .{ .w = w, .h = h };
        b.depth = 0;
        @memset(b.cells, .{});
    }

    pub fn area(b: *const Buffer) Rect {
        return .{ .w = b.w, .h = b.h };
    }

    pub fn at(b: *Buffer, x: u16, y: u16) ?*Cell {
        if (x >= b.w or y >= b.h) return null;
        return &b.cells[@as(usize, y) * @as(usize, b.w) + @as(usize, x)];
    }

    pub fn clear(b: *Buffer, style: Style) void {
        @memset(b.cells, .{ .style = style });
    }

    pub fn fill(b: *Buffer, r: Rect, glyph: []const u8, style: Style) void {
        // Edge sums in u32: `x + w` may exceed maxInt(u16), and positions past
        // it are unaddressable anyway.
        const x_end = @min(@as(u32, r.x) + r.w, @as(u32, std.math.maxInt(u16)) + 1);
        const y_end = @min(@as(u32, r.y) + r.h, @as(u32, std.math.maxInt(u16)) + 1);
        var y: u32 = r.y;
        while (y < y_end) : (y += 1) {
            var x: u32 = r.x;
            while (x < x_end) : (x += 1) {
                b.setCell(@intCast(x), @intCast(y), glyph, 1, style);
            }
        }
    }

    /// Writes one grapheme cluster at an absolute position, unclipped.
    ///
    /// Public because `blit` writes cells the emulator already laid out: it
    /// knows each cluster's width from the pane's own tables and must not have
    /// them measured a second time.
    pub fn setCell(b: *Buffer, x: u16, y: u16, bytes: []const u8, width: u8, style: Style) void {
        if (!b.clip.contains(x, y)) return;

        // A wide glyph occupies the next column whether or not that column is
        // ours to write. Drawing the head alone makes the terminal advance two
        // columns and paint over the neighbour, so the glyph is replaced by a
        // blank that stays inside the clip.
        const fits = width != 2 or
            (x < std.math.maxInt(u16) and b.clip.contains(x + 1, y));
        const text = if (fits) bytes else " ";
        const drawn: u8 = if (fits) width else 1;

        const cell = b.at(x, y) orelse return;
        var len: u8 = @intCast(@min(text.len, Cell.max_bytes));
        // A cluster longer than the cell is cut, but never mid-codepoint:
        // invalid UTF-8 stored here would reach the host terminal verbatim.
        if (len < text.len) {
            while (len > 0 and text[len] & 0xc0 == 0x80) len -= 1;
        }
        cell.* = .{ .len = len, .width = drawn, .style = style };
        @memcpy(cell.bytes[0..len], text[0..len]);

        // The second column of a wide glyph. Width 0 keeps the diff from
        // emitting anything there and keeps a later write from leaving half of
        // a character behind.
        if (drawn == 2) {
            if (b.at(x + 1, y)) |tail| tail.* = .{ .len = 0, .width = 0, .style = style };
        }
    }

    /// Draws `text` at (x, y), clipped to `r`. Returns the columns advanced.
    ///
    /// Iteration is by grapheme cluster, and the width comes from the same
    /// table the build bound to `unicode`, which by default is the one laying
    /// out the agents' own output. Anything else - counting bytes, counting
    /// codepoints, guessing at emoji - drifts from what the terminal actually
    /// does, and a UI whose idea of a column disagrees with the terminal's
    /// smears on the first accented character.
    pub fn writeText(b: *Buffer, r: Rect, x: u16, y: u16, text: []const u8, style: Style) u16 {
        if (y < r.y or y >= @as(u32, r.y) + r.h) return 0;

        var column: u32 = x;
        const limit = @min(@as(u32, r.x) + r.w, @as(u32, std.math.maxInt(u16)) + 1);
        var it: GraphemeIterator = .{ .bytes = text };

        while (it.next()) |cluster| {
            if (column >= limit) break;
            // A wide glyph that would straddle the edge is dropped rather than
            // cut in half.
            if (cluster.width == 2 and column + 1 >= limit) break;
            if (column >= r.x) {
                b.setCell(@intCast(column), y, cluster.bytes, cluster.width, style);
            }
            column += cluster.width;
        }
        return @intCast(@min(column - x, std.math.maxInt(u16)));
    }

    /// Draws `text`, appending an ellipsis if it does not fit in `max_width`.
    ///
    /// The ellipsis has to be measured too, and the cut has to land on a
    /// grapheme boundary: truncating by bytes is how a name ending in an accent
    /// turns into a replacement character.
    pub fn writeTruncated(
        b: *Buffer,
        r: Rect,
        x: u16,
        y: u16,
        text: []const u8,
        max_width: u16,
        style: Style,
    ) u16 {
        if (max_width == 0) return 0;
        if (measure(text) <= max_width) return b.writeText(r, x, y, text, style);

        // Measured, not assumed to be one column. It is one in every real
        // table, but reserving a column and then drawing something wider is
        // how a truncation overruns the box it was supposed to fit inside.
        const ellipsis = "\u{2026}";
        const marker = measure(ellipsis);
        // Not even room for the marker. Drawing it alone would say a value was
        // cut without saying anything about the value.
        if (marker >= max_width) return 0;
        const budget = max_width - marker;

        var it: GraphemeIterator = .{ .bytes = text };
        var used: u32 = 0;
        var cut: usize = 0;
        while (it.next()) |cluster| {
            if (used + cluster.width > budget) break;
            used += cluster.width;
            cut = it.index;
        }
        const written = b.writeText(r, x, y, text[0..cut], style);
        const ellipsis_x = @as(u32, x) + written;
        if (ellipsis_x > std.math.maxInt(u16)) return written;
        return written + b.writeText(r, @intCast(ellipsis_x), y, ellipsis, style);
    }

    /// Draws the end of `text`, prepending an ellipsis when it does not fit.
    /// Paths use this form because their basename carries more information
    /// than a repeated home-directory prefix.
    pub fn writeLeftTruncated(
        b: *Buffer,
        r: Rect,
        x: u16,
        y: u16,
        text: []const u8,
        max_width: u16,
        style: Style,
    ) u16 {
        if (max_width == 0) return 0;
        const total = measure(text);
        if (total <= max_width) return b.writeText(r, x, y, text, style);

        const ellipsis = "\u{2026}";
        const marker = measure(ellipsis);
        if (marker >= max_width) return 0;
        const budget = max_width - marker;
        var it: GraphemeIterator = .{ .bytes = text };
        var prefix_width: u32 = 0;
        var cut: usize = text.len;
        while (true) {
            const cluster_start = it.index;
            const cluster = it.next() orelse break;
            if (total - prefix_width <= budget) {
                cut = cluster_start;
                break;
            }
            prefix_width += cluster.width;
        }
        const written = b.writeText(r, x, y, ellipsis, style);
        const text_x = @as(u32, x) + written;
        if (text_x > std.math.maxInt(u16)) return written;
        return written + b.writeText(r, @intCast(text_x), y, text[cut..], style);
    }

    /// Draws `text` so that it ends at the right edge of `r`.
    pub fn writeRight(b: *Buffer, r: Rect, y: u16, text: []const u8, style: Style) u16 {
        const width = measure(text);
        if (width > r.w) return b.writeTruncated(r, r.x, y, text, r.w, style);
        const start = @as(u32, r.x) + (r.w - width);
        if (start > std.math.maxInt(u16)) return 0;
        return b.writeText(r, @intCast(start), y, text, style);
    }

    /// Draws a box, with an optional title in the top edge.
    pub fn box(b: *Buffer, r: Rect, style: Style, title: ?[]const u8) void {
        if (r.w < 2 or r.h < 2) return;
        // A box whose far edge leaves the addressable plane cannot be drawn
        // whole, and a partial box misleads more than no box.
        if (@as(u32, r.x) + r.w - 1 > std.math.maxInt(u16) or
            @as(u32, r.y) + r.h - 1 > std.math.maxInt(u16)) return;
        const right = r.x + r.w - 1;
        const bottom = r.y + r.h - 1;

        var x = r.x + 1;
        while (x < right) : (x += 1) {
            b.setCell(x, r.y, "─", 1, style);
            b.setCell(x, bottom, "─", 1, style);
        }
        var y = r.y + 1;
        while (y < bottom) : (y += 1) {
            b.setCell(r.x, y, "│", 1, style);
            b.setCell(right, y, "│", 1, style);
        }
        b.setCell(r.x, r.y, "╭", 1, style);
        b.setCell(right, r.y, "╮", 1, style);
        b.setCell(r.x, bottom, "╰", 1, style);
        b.setCell(right, bottom, "╯", 1, style);

        if (title) |t| {
            const inside: Rect = .{ .x = r.x + 2, .y = r.y, .w = r.w -| 4, .h = 1 };
            _ = b.writeText(inside, r.x + 2, r.y, t, style);
        }
    }

    /// Draws a box on the outside edge of its cells.
    ///
    /// Box-drawing glyphs sit around the centre of a cell. When the cell also
    /// carries a panel background, half of that background appears outside the
    /// visible line. Edge-aligned side blocks and terminal decorations keep
    /// the entire cell on the inside of the frame instead.
    pub fn edgeBox(b: *Buffer, r: Rect, style: Style, title: ?[]const u8) void {
        if (r.w < 2 or r.h < 2) return;
        if (@as(u32, r.x) + r.w - 1 > std.math.maxInt(u16) or
            @as(u32, r.y) + r.h - 1 > std.math.maxInt(u16)) return;
        const right = r.x + r.w - 1;
        const bottom = r.y + r.h - 1;

        var top_style = style;
        top_style.flags.overline = true;
        var bottom_style = style;
        bottom_style.flags.underline = .single;
        bottom_style.underline_color = style.fg;

        var x = r.x;
        while (x < right) : (x += 1) {
            b.setCell(x, r.y, " ", 1, top_style);
            b.setCell(x, bottom, " ", 1, bottom_style);
        }
        b.setCell(right, r.y, " ", 1, top_style);
        b.setCell(right, bottom, " ", 1, bottom_style);
        var y = r.y + 1;
        while (y < bottom) : (y += 1) {
            b.setCell(r.x, y, "▏", 1, style);
            b.setCell(right, y, "▕", 1, style);
        }
        b.setCell(r.x, r.y, "▏", 1, top_style);
        b.setCell(right, r.y, "▕", 1, top_style);
        b.setCell(r.x, bottom, "▏", 1, bottom_style);
        b.setCell(right, bottom, "▕", 1, bottom_style);

        if (title) |t| {
            const inside: Rect = .{ .x = r.x + 2, .y = r.y, .w = r.w -| 4, .h = 1 };
            _ = b.writeText(inside, r.x + 2, r.y, t, top_style);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "text is written by grapheme, not by byte" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    // Six bytes, three codepoints, three columns.
    const advanced = buf.writeText(buf.area(), 0, 0, "áéí", .{});
    try testing.expectEqual(@as(u16, 3), advanced);
    try testing.expectEqualStrings("á", buf.at(0, 0).?.text());
    try testing.expectEqualStrings("í", buf.at(2, 0).?.text());
}

test "a wide glyph claims the column after it" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    const advanced = buf.writeText(buf.area(), 0, 0, "漢字", .{});
    try testing.expectEqual(@as(u16, 4), advanced);
    try testing.expectEqual(@as(u8, 2), buf.at(0, 0).?.width);
    // The trailing half is addressable but draws nothing.
    try testing.expectEqual(@as(u8, 0), buf.at(1, 0).?.width);
    try testing.expectEqual(@as(u8, 2), buf.at(2, 0).?.width);
}

test "a wide glyph is dropped rather than cut in half at the edge" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 3, 1);
    defer buf.deinit();

    // Two columns fit; the second wide glyph does not, and half of one is
    // worse than none of it.
    const advanced = buf.writeText(buf.area(), 0, 0, "漢字", .{});
    try testing.expectEqual(@as(u16, 2), advanced);
    try testing.expectEqualStrings(" ", buf.at(2, 0).?.text());
}

test "writing is clipped to the area, not to the buffer" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    const area: Rect = .{ .x = 2, .y = 0, .w = 4, .h = 1 };
    _ = buf.writeText(area, 2, 0, "abcdefgh", .{});

    try testing.expectEqualStrings("a", buf.at(2, 0).?.text());
    try testing.expectEqualStrings("d", buf.at(5, 0).?.text());
    // Past the area, untouched.
    try testing.expectEqualStrings(" ", buf.at(6, 0).?.text());
}

test "invalid utf-8 becomes one cell instead of failing" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 10, 1);
    defer buf.deinit();

    // Agents print partial writes; the UI has to survive them.
    const advanced = buf.writeText(buf.area(), 0, 0, "a\xffb", .{});
    try testing.expectEqual(@as(u16, 3), advanced);
    try testing.expectEqualStrings("a", buf.at(0, 0).?.text());
    try testing.expectEqualStrings("b", buf.at(2, 0).?.text());
}

test "truncation lands on a grapheme boundary and leaves room for the ellipsis" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    // Cutting "booking-flow-copy" by bytes at the same point would be fine, but
    // cutting an accented name would not, so the cut is by cluster either way.
    const written = buf.writeTruncated(buf.area(), 0, 0, "booking-flow-copy", 8, .{});
    try testing.expectEqual(@as(u16, 8), written);
    try testing.expectEqualStrings("\u{2026}", buf.at(7, 0).?.text());
    try testing.expectEqualStrings("b", buf.at(0, 0).?.text());
}

test "truncation never splits a wide glyph" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    // Four columns available, one for the ellipsis, so one wide glyph fits.
    const written = buf.writeTruncated(buf.area(), 0, 0, "漢字漢字", 4, .{});
    try testing.expect(written <= 4);
    try testing.expectEqual(@as(u8, 2), buf.at(0, 0).?.width);
}

test "left truncation preserves the path suffix on a grapheme boundary" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    const written = buf.writeLeftTruncated(buf.area(), 0, 0, "~/projects/café/telar", 8, .{});
    try testing.expectEqual(@as(u16, 8), written);
    try testing.expectEqualStrings("\u{2026}", buf.at(0, 0).?.text());
    try testing.expectEqualStrings("t", buf.at(3, 0).?.text());
    try testing.expectEqualStrings("r", buf.at(7, 0).?.text());
}

test "text that fits is not truncated" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();
    const written = buf.writeTruncated(buf.area(), 0, 0, "main", 10, .{});
    try testing.expectEqual(@as(u16, 4), written);
    try testing.expectEqualStrings(" ", buf.at(4, 0).?.text());
}

test "right aligned text ends at the right edge" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    const r: Rect = .{ .x = 0, .y = 0, .w = 20, .h = 1 };
    _ = buf.writeRight(r, 0, "6 tasks", .{});
    try testing.expectEqualStrings("s", buf.at(19, 0).?.text());
    try testing.expectEqualStrings("6", buf.at(13, 0).?.text());
}

test "an edge box keeps its background inside the visible frame" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 8, 5);
    defer buf.deinit();

    const background: cell_mod.Color = .{ .rgb = .{ 20, 21, 22 } };
    const accent: cell_mod.Color = .{ .rgb = .{ 230, 180, 120 } };
    const area: Rect = .{ .x = 1, .y = 1, .w = 6, .h = 3 };
    buf.fill(area, " ", .{ .bg = background });
    buf.edgeBox(area, .{ .fg = accent, .bg = background }, "hi");

    try testing.expect(buf.at(1, 1).?.style.flags.overline);
    try testing.expectEqualStrings("▏", buf.at(1, 1).?.text());
    try testing.expectEqualStrings("▕", buf.at(6, 2).?.text());
    try testing.expectEqual(Style.Underline.single, buf.at(3, 3).?.style.flags.underline);
    try testing.expect(std.meta.eql(buf.at(3, 3).?.style.underline_color, accent));
    try testing.expect(std.meta.eql(buf.at(1, 2).?.style.bg, background));
    try testing.expect(std.meta.eql(buf.at(0, 2).?.style.bg, cell_mod.Color.default));
    try testing.expectEqualStrings("h", buf.at(3, 1).?.text());
    try testing.expect(buf.at(3, 1).?.style.flags.overline);
}

test "an oversized cluster is truncated on a codepoint boundary" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 4, 1);
    defer buf.deinit();

    // Man, ZWJ, rocket, ZWJ, man: 18 bytes, so the 16-byte cell cannot hold
    // it. Cutting mid-codepoint would store invalid UTF-8 that later reaches
    // the host terminal verbatim.
    const cluster = "\u{1F468}\u{200D}\u{1F680}\u{200D}\u{1F468}";
    try testing.expect(cluster.len > Cell.max_bytes);
    buf.setCell(0, 0, cluster, 2, .{});
    const stored = buf.at(0, 0).?.text();
    try testing.expect(std.unicode.utf8ValidateSlice(stored));
    // The whole first three codepoints survive; the cut codepoint is dropped.
    try testing.expectEqualStrings("\u{1F468}\u{200D}\u{1F680}\u{200D}", stored);
}

test "a clip stops a widget damaging its neighbours" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 3);
    defer buf.deinit();
    buf.fill(buf.area(), ".", .{});

    // A label longer than the box it was given. Without a clip the overflow
    // lands on whatever is drawn to the right, and the symptom is a neighbour
    // that flickers only when this one has a long name.
    buf.pushClip(.{ .x = 2, .y = 1, .w = 4, .h = 1 });
    _ = buf.writeText(buf.area(), 2, 1, "abcdefghij", .{});
    buf.popClip();

    try testing.expectEqualStrings("a", buf.at(2, 1).?.text());
    try testing.expectEqualStrings("d", buf.at(5, 1).?.text());
    // One past the clip, and the row above, both untouched.
    try testing.expectEqualStrings(".", buf.at(6, 1).?.text());
    try testing.expectEqualStrings(".", buf.at(2, 0).?.text());
}

test "a nested clip cannot be wider than its parent" {
    // The escape hatch clipping exists to close: a child that asks for more
    // room than it was given would otherwise get it.
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();
    buf.fill(buf.area(), ".", .{});

    buf.pushClip(.{ .x = 5, .y = 0, .w = 4, .h = 1 });
    buf.pushClip(buf.area()); // asks for everything
    buf.fill(buf.area(), "#", .{});
    buf.popClip();
    buf.popClip();

    try testing.expectEqualStrings(".", buf.at(4, 0).?.text());
    try testing.expectEqualStrings("#", buf.at(5, 0).?.text());
    try testing.expectEqualStrings("#", buf.at(8, 0).?.text());
    try testing.expectEqualStrings(".", buf.at(9, 0).?.text());
}

test "popping restores the parent clip" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 10, 1);
    defer buf.deinit();

    buf.pushClip(.{ .x = 0, .y = 0, .w = 2, .h = 1 });
    buf.popClip();
    _ = buf.writeText(buf.area(), 0, 0, "abcdef", .{});
    try testing.expectEqualStrings("f", buf.at(5, 0).?.text());
}

test "a wide glyph cut by the clip becomes a blank, not half a character" {
    // Drawing only the head makes the terminal advance two columns and paint
    // over the neighbour, so the clip would leak by exactly one column - the
    // hardest kind of bleed to notice and the easiest to blame on the font.
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 10, 1);
    defer buf.deinit();
    buf.fill(buf.area(), ".", .{});

    buf.pushClip(.{ .x = 0, .y = 0, .w = 3, .h = 1 });
    buf.setCell(2, 0, "漢", 2, .{});
    buf.popClip();

    try testing.expectEqual(@as(u8, 1), buf.at(2, 0).?.width);
    try testing.expectEqualStrings(" ", buf.at(2, 0).?.text());
    try testing.expectEqualStrings(".", buf.at(3, 0).?.text());
}

test "resizing forgets a clip that described the old buffer" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 4, 1);
    defer buf.deinit();

    buf.pushClip(.{ .x = 0, .y = 0, .w = 2, .h = 1 });
    try buf.resize(10, 1);
    // A stale clip here silently drops everything past column two, and the
    // symptom is a window that only half redraws after being made bigger.
    _ = buf.writeText(buf.area(), 0, 0, "abcdefgh", .{});
    try testing.expectEqualStrings("h", buf.at(7, 0).?.text());
}
