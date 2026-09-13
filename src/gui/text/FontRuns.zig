//! Groups whole graphemes by face, retaining contextual shaping within each span.
const core = @import("telar-core");
const FontSet = @import("FontSet.zig");
const FontRun = @import("FontRun.zig");
const Braille = @import("Braille.zig");
const FontRuns = @This();

fonts: *const FontSet,
iterator: core.GraphemeIterator,

/// Borrows slices of the original UTF-8; unsupported clusters remain in primary.
/// Example: `while (runs.next()) |run| { ... }`
pub fn next(runs: *FontRuns) ?FontRun {
    const start = runs.iterator.index;
    const first = runs.iterator.next() orelse return null;
    if (Braille.parse(first.bytes)) |pattern| {
        return .{ .text = runs.iterator.bytes[start..runs.iterator.index], .source = .{ .braille = pattern }, .columns = first.width };
    }

    const id = runs.fonts.source(first.bytes);
    if (id != .primary) {
        return .{ .text = runs.iterator.bytes[start..runs.iterator.index], .source = .{ .font = id }, .columns = first.width };
    }

    var columns: u32 = first.width;
    while (true) {
        const previous = runs.iterator.index;
        const cluster = runs.iterator.next() orelse break;
        if (Braille.parse(cluster.bytes) != null or runs.fonts.source(cluster.bytes) != id) {
            runs.iterator.index = previous;
            break;
        }

        columns += cluster.width;
    }

    return .{ .text = runs.iterator.bytes[start..runs.iterator.index], .source = .{ .font = id }, .columns = columns };
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
