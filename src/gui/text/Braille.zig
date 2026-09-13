//! Procedural Unicode Braille patterns; each bit owns one dot in a 2 by 4 cell.
const std = @import("std");
const TextRun = @import("TextRun.zig");
const Grid = @import("BrailleGrid.zig");
const QuadList = @import("../render/QuadList.zig");
const Braille = @This();

dots: u8,

/// Accepts exactly one bare Braille grapheme, preserving attached marks for shaping.
/// Example: `const pattern = Braille.parse("\u{2801}") orelse return;`
pub fn parse(text: []const u8) ?Braille {
    if (text.len != 3 or text[0] != 0xe2 or text[1] < 0xa0 or text[1] > 0xa3 or text[2] < 0x80 or text[2] > 0xbf) {
        return null;
    }

    return .{ .dots = ((text[1] & 3) << 6) | (text[2] & 63) };
}

/// Uses the caller's cell bounds relative to its baseline; no font or atlas lookup.
/// Example: `_ = try pattern.paint(run, quads);`
pub fn paint(pattern: Braille, run: TextRun, list: *QuadList) !f32 {
    var bounds = run.cell_bounds orelse return error.MissingCellBounds;
    bounds.x += run.x;
    bounds.y += run.y;
    const grid = try Grid.init(bounds);
    if (grid.diameter == 0) {
        return bounds.width;
    }

    const columns = [_]u1{ 0, 0, 0, 1, 1, 1, 0, 1 };
    const rows = [_]u2{ 0, 1, 2, 0, 1, 2, 3, 3 };
    for (columns, rows, 0..) |column, row, bit| {
        if (pattern.dots & (@as(u8, 1) << @intCast(bit)) == 0) {
            continue;
        }

        try list.pushRect(.{ .x = grid.x[column], .y = grid.y[row], .width = grid.diameter, .height = grid.diameter }, run.color);
    }

    return bounds.width;
}

test "all 256 patterns encode the Unicode dot order with solid quads" {
    const quad = @import("../render/Quad.zig");
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    try list.reserve(8);
    const expected_x = [_]f32{ 11, 11, 11, 19, 19, 19, 11, 19 };
    const expected_y = [_]f32{ 23, 31, 39, 23, 31, 39, 47, 47 };
    for (0..256) |mask| {
        var bytes: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(@intCast(0x2800 + mask), &bytes);
        const pattern = parse(bytes[0..length]).?;
        try std.testing.expectEqual(@as(u8, @intCast(mask)), pattern.dots);
        list.clear();
        const advance = try pattern.paint(.{ .text = bytes[0..length], .x = 8.5, .y = 40.25, .color = .{ .r = 0.3, .g = 0.5, .b = 0.7, .a = 0.4 }, .pixel_height = 28, .cell_bounds = .{ .x = 0.5, .y = -19.25, .width = 16, .height = 32 } }, &list);
        try std.testing.expectEqual(@as(f32, 16), advance);
        try std.testing.expectEqual(@as(usize, @popCount(pattern.dots)), list.items().len);
        var index: usize = 0;
        for (0..8) |bit| {
            if (mask & (@as(usize, 1) << @intCast(bit)) == 0) {
                continue;
            }

            const dot = list.items()[index];
            index += 1;
            try std.testing.expectEqual(expected_x[bit], dot.x);
            try std.testing.expectEqual(expected_y[bit], dot.y);
            try std.testing.expectEqual(@as(f32, 4), dot.width);
            try std.testing.expectEqual(dot.width, dot.height);
            try std.testing.expectEqual(quad.solid_uv, [_]f32{ dot.u0, dot.v0, dot.u1, dot.v1 });
            try std.testing.expectEqual([_]f32{ 0.3, 0.5, 0.7, 0.4 }, [_]f32{ dot.r, dot.g, dot.b, dot.a });
        }
    }
}

test "only complete bare Braille graphemes bypass text shaping" {
    const rejected = [_][]const u8{ "", "A", "\u{27ff}", "\u{2900}", "\xe2", "\xe2\xa0", "\xe2\xa0\x7f", "\xe2\xa0\xc0", "\u{2801}\u{301}", "\u{2801}\u{fe0f}", "\u{2801}\u{2802}" };
    for (rejected) |bytes| {
        try std.testing.expectEqual(@as(?Braille, null), parse(bytes));
    }
}

test "blank and zero-area Braille produce no ink" {
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    var run: TextRun = .{ .text = "", .x = 0, .y = 0, .color = .white, .pixel_height = 16, .cell_bounds = .{ .x = 0, .y = 0, .width = 16, .height = 32 } };
    try std.testing.expectEqual(@as(f32, 16), try (Braille{ .dots = 0 }).paint(run, &list));
    run.cell_bounds.?.height = 0;
    try std.testing.expectEqual(@as(f32, 16), try (Braille{ .dots = 255 }).paint(run, &list));
    run.cell_bounds.?.height = 32;
    run.cell_bounds.?.width = 0;
    try std.testing.expectEqual(@as(f32, 0), try (Braille{ .dots = 255 }).paint(run, &list));
    try std.testing.expectEqual(@as(usize, 0), list.items().len);
}
