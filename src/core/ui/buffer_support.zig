//! The grid to draw into.
//!
//! Knows nothing about the terminal, which is what makes every widget testable:
//! draw into a buffer, then assert on cells. A widget is not a type here - it
//! is `fn (buf: *Buffer, area: Rect, ...) void`, and that is the whole
//! extension mechanism.

const std = @import("std");
const geometry = @import("geometry.zig");
pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
const cell_mod = @import("cell_support.zig");
pub const Cell = cell_mod.Cell;
pub const Style = cell_mod.Style;
const text_mod = @import("text.zig");
pub const measure = text_mod.measure;
pub const GraphemeIterator = text_mod.GraphemeIterator;

pub const Buffer = @import("Buffer.zig");

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "text is written by grapheme, not by byte" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    // Six bytes, three codepoints, three columns.
    const advanced = buf.writeText(buf.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "áéí", .style = .{} });
    try testing.expectEqual(@as(u16, 3), advanced);
    try testing.expectEqualStrings("á", buf.at(0, 0).?.text());
    try testing.expectEqualStrings("í", buf.at(2, 0).?.text());
}

test "a wide glyph claims the column after it" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    const advanced = buf.writeText(buf.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "漢字", .style = .{} });
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
    const advanced = buf.writeText(buf.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "漢字", .style = .{} });
    try testing.expectEqual(@as(u16, 2), advanced);
    try testing.expectEqualStrings(" ", buf.at(2, 0).?.text());
}

test "writing is clipped to the area, not to the buffer" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    const area: Rect = .{ .x = 2, .y = 0, .w = 4, .h = 1 };
    _ = buf.writeText(area, .{ .point = .{ .x = 2, .y = 0 }, .text = "abcdefgh", .style = .{} });

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
    const advanced = buf.writeText(buf.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "a\xffb", .style = .{} });
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
    const written = buf.writeTruncated(buf.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "booking-flow-copy", .max_width = 8, .style = .{} });
    try testing.expectEqual(@as(u16, 8), written);
    try testing.expectEqualStrings("\u{2026}", buf.at(7, 0).?.text());
    try testing.expectEqualStrings("b", buf.at(0, 0).?.text());
}

test "truncation never splits a wide glyph" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    // Four columns available, one for the ellipsis, so one wide glyph fits.
    const written = buf.writeTruncated(buf.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "漢字漢字", .max_width = 4, .style = .{} });
    try testing.expect(written <= 4);
    try testing.expectEqual(@as(u8, 2), buf.at(0, 0).?.width);
}

test "left truncation preserves the path suffix on a grapheme boundary" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    const written = buf.writeLeftTruncated(buf.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "~/projects/café/telar", .max_width = 8 });
    try testing.expectEqual(@as(u16, 8), written);
    try testing.expectEqualStrings("\u{2026}", buf.at(0, 0).?.text());
    try testing.expectEqualStrings("t", buf.at(3, 0).?.text());
    try testing.expectEqualStrings("r", buf.at(7, 0).?.text());
}

test "text that fits is not truncated" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();
    const written = buf.writeTruncated(buf.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "main", .max_width = 10, .style = .{} });
    try testing.expectEqual(@as(u16, 4), written);
    try testing.expectEqualStrings(" ", buf.at(4, 0).?.text());
}

test "right aligned text ends at the right edge" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    const r: Rect = .{ .x = 0, .y = 0, .w = 20, .h = 1 };
    _ = buf.writeRight(r, .{ .y = 0, .text = "6 tasks" });
    try testing.expectEqualStrings("s", buf.at(19, 0).?.text());
    try testing.expectEqualStrings("6", buf.at(13, 0).?.text());
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
    buf.setCell(.{ .x = 0, .y = 0 }, .{ .text = cluster, .width = 2, .style = .{} });
    const stored = buf.at(0, 0).?.text();
    try testing.expect(std.unicode.utf8ValidateSlice(stored));
    // The whole first three codepoints survive; the cut codepoint is dropped.
    try testing.expectEqualStrings("\u{1F468}\u{200D}\u{1F680}\u{200D}", stored);
}

test "a clip stops a widget damaging its neighbours" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 3);
    defer buf.deinit();
    buf.fill(buf.area(), .{ .glyph = ".", .style = .{} });

    // A label longer than the box it was given. Without a clip the overflow
    // lands on whatever is drawn to the right, and the symptom is a neighbour
    // that flickers only when this one has a long name.
    buf.pushClip(.{ .x = 2, .y = 1, .w = 4, .h = 1 });
    _ = buf.writeText(buf.area(), .{ .point = .{ .x = 2, .y = 1 }, .text = "abcdefghij", .style = .{} });
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
    buf.fill(buf.area(), .{ .glyph = ".", .style = .{} });

    buf.pushClip(.{ .x = 5, .y = 0, .w = 4, .h = 1 });
    buf.pushClip(buf.area()); // asks for everything
    buf.fill(buf.area(), .{ .glyph = "#", .style = .{} });
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
    _ = buf.writeText(buf.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "abcdef", .style = .{} });
    try testing.expectEqualStrings("f", buf.at(5, 0).?.text());
}

test "a wide glyph cut by the clip becomes a blank, not half a character" {
    // Drawing only the head makes the terminal advance two columns and paint
    // over the neighbour, so the clip would leak by exactly one column - the
    // hardest kind of bleed to notice and the easiest to blame on the font.
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 10, 1);
    defer buf.deinit();
    buf.fill(buf.area(), .{ .glyph = ".", .style = .{} });

    buf.pushClip(.{ .x = 0, .y = 0, .w = 3, .h = 1 });
    buf.setCell(.{ .x = 2, .y = 0 }, .{ .text = "漢", .width = 2, .style = .{} });
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
    _ = buf.writeText(buf.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "abcdefgh", .style = .{} });
    try testing.expectEqualStrings("h", buf.at(7, 0).?.text());
}
