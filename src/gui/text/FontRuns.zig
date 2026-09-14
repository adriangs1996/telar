//! Groups whole graphemes by face, retaining contextual shaping within each span.
const core = @import("telar-core");
const FontSet = @import("FontSet.zig");
const FontRun = @import("FontRun.zig");
const Box = @import("BoxDrawing.zig");
const Block = @import("BlockElement.zig");
const Braille = @import("Braille.zig");
const Id = @import("font_id.zig").Id;
const FontRuns = @This();

fonts: *const FontSet,
iterator: core.GraphemeIterator,
/// The face a caller asked for; graphemes it lacks follow the terminal chain.
preferred: Id = .primary,

/// Borrows slices of the original UTF-8; unsupported clusters remain in primary.
/// Consecutive graphemes of the preferred face share one span; every other
/// grapheme is its own span so fitted fallback ink keeps one cell advance.
/// Example: `while (runs.next()) |run| { ... }`
pub fn next(runs: *FontRuns) ?FontRun {
    const start = runs.iterator.index;
    const first = runs.iterator.next() orelse return null;
    if (Braille.parse(first.bytes)) |pattern| {
        return .{ .text = runs.iterator.bytes[start..runs.iterator.index], .source = .{ .braille = pattern }, .columns = first.width };
    }

    if (Box.parse(first.bytes)) |box| {
        return .{ .text = runs.iterator.bytes[start..runs.iterator.index], .source = .{ .box = box }, .columns = first.width };
    }

    if (Block.parse(first.bytes)) |block| {
        return .{ .text = runs.iterator.bytes[start..runs.iterator.index], .source = .{ .block = block }, .columns = first.width };
    }

    const id = runs.fonts.source(first.bytes, runs.preferred);
    if (id != runs.preferred) {
        return .{ .text = runs.iterator.bytes[start..runs.iterator.index], .source = .{ .font = id }, .columns = first.width, .preferred = runs.preferred };
    }

    var columns: u32 = first.width;
    while (true) {
        const previous = runs.iterator.index;
        const cluster = runs.iterator.next() orelse break;
        if (Braille.parse(cluster.bytes) != null or Box.parse(cluster.bytes) != null or Block.parse(cluster.bytes) != null or runs.fonts.source(cluster.bytes, runs.preferred) != id) {
            runs.iterator.index = previous;
            break;
        }

        columns += cluster.width;
    }

    return .{ .text = runs.iterator.bytes[start..runs.iterator.index], .source = .{ .font = id }, .columns = columns, .preferred = runs.preferred };
}

test "Braille separates font spans without splitting combining graphemes" {
    const std = @import("std");
    var atlas = try @import("GlyphAtlas.zig").init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var runs: FontRuns = .{ .fonts = &atlas.fonts, .iterator = .{ .bytes = "office\u{301}\u{2801}\u{2802}\u{301}ffi" } };
    const before = runs.next().?;
    try std.testing.expectEqualStrings("office\u{301}", before.text);
    try std.testing.expectEqual(.font, std.meta.activeTag(before.source));
    const braille = runs.next().?;
    try std.testing.expectEqualStrings("\u{2801}", braille.text);
    try std.testing.expectEqual(@as(u8, 1), braille.source.braille.dots);
    try std.testing.expectEqual(@as(u32, 1), braille.columns);
    const after = runs.next().?;
    try std.testing.expectEqualStrings("\u{2802}\u{301}ffi", after.text);
    try std.testing.expectEqual(.font, std.meta.activeTag(after.source));
    try std.testing.expectEqual(@as(?FontRun, null), runs.next());
}

test "box drawing keeps contextual text and marked boxes in whole font spans" {
    const std = @import("std");
    var atlas = try @import("GlyphAtlas.zig").init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var runs: FontRuns = .{ .fonts = &atlas.fonts, .iterator = .{ .bytes = "office\u{301}╭│\u{301}ffi" } };
    try std.testing.expectEqualStrings("office\u{301}", runs.next().?.text);
    const box = runs.next().?;
    try std.testing.expectEqual(@as(u21, 0x256d), box.source.box.codepoint);
    const after = runs.next().?;
    try std.testing.expectEqualStrings("│\u{301}ffi", after.text);
    try std.testing.expectEqual(.font, std.meta.activeTag(after.source));
    try std.testing.expectEqual(@as(?FontRun, null), runs.next());
}

test "block elements separate font spans while marked blocks stay in the font path" {
    const std = @import("std");
    var atlas = try @import("GlyphAtlas.zig").init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var runs: FontRuns = .{ .fonts = &atlas.fonts, .iterator = .{ .bytes = "office\u{301}▐▛\u{fe0f}█\u{301}ffi" } };
    try std.testing.expectEqualStrings("office\u{301}", runs.next().?.text);
    const block = runs.next().?;
    try std.testing.expectEqualStrings("▐", block.text);
    try std.testing.expectEqual(@as(u21, 0x2590), block.source.block.codepoint);
    try std.testing.expectEqual(@as(u32, 1), block.columns);
    const after = runs.next().?;
    try std.testing.expectEqualStrings("▛\u{fe0f}█\u{301}ffi", after.text);
    try std.testing.expectEqual(.font, std.meta.activeTag(after.source));
    try std.testing.expectEqual(@as(?FontRun, null), runs.next());
}
