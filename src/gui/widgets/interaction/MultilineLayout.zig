//! Wrapping shared by composer drawing, pointer selection and native IME.
const core = @import("telar-core");
const WrappedLines = @import("EditorLines.zig");
const Layout = @This();

text: []const u8,
head: u32,
columns: u16,
rows: u32,
font: ?@import("EditorFont.zig") = null,

/// Returns the first visible row while keeping the caret inside the editor.
/// Example: `const first = layout.firstRow();`
pub fn firstRow(layout: Layout) u32 {
    return layout.position(layout.head)[1] -| (layout.rows -| 1);
}

/// Measures a byte offset in wrapped columns and rows without allocating.
/// Example: `const caret = layout.position(field.head);`
pub fn position(layout: Layout, at: u32) [2]u32 {
    var lines: WrappedLines = .{ .text = layout.text, .width = layout.columns, .font = layout.font };
    var row: u32 = 0;
    while (lines.next()) |line| {
        const start = @intFromPtr(line.ptr) - @intFromPtr(layout.text.ptr);
        const end = start + line.len;
        if (at < end or (at == end and (lines.finished or end < layout.text.len and (layout.text[end] == '\n' or layout.text[end] == '\r')))) {
            const column = lines.position(at -| start);
            return .{ column, row };
        }

        row += 1;
    }

    return .{ 0, row -| 1 };
}

/// Maps a pointer in measured units to a complete grapheme in the visible rows.
/// Example: `const offset = layout.offset(.{ column, row });`
pub fn offset(layout: Layout, point: [2]f64) u32 {
    const wanted = layout.firstRow() + @as(u32, @intFromFloat(@max(0, @min(65535, @floor(point[1])))));
    var lines: WrappedLines = .{ .text = layout.text, .width = layout.columns, .font = layout.font };
    var row: u32 = 0;
    while (lines.next()) |line| {
        if (row != wanted) {
            row += 1;
            continue;
        }

        const start: u32 = @intCast(@intFromPtr(line.ptr) - @intFromPtr(layout.text.ptr));
        var at = start;
        var used: f64 = @floatFromInt(lines.position(0));
        var nearest = @abs(point[0] - used);
        var iterator: core.GraphemeIterator = .{ .bytes = line };
        while (iterator.next()) |cluster| {
            used = if (layout.font != null) @floatFromInt(lines.position(iterator.index)) else used + @as(f64, @floatFromInt(cluster.width));
            const distance = @abs(point[0] - used);
            if (distance <= nearest) {
                nearest = distance;
                at = start + @as(u32, @intCast(iterator.index));
            }
        }

        return at;
    }

    return @intCast(layout.text.len);
}

test "wrapped composer caret and pointer agree at UTF8 and newline boundaries" {
    const std = @import("std");
    const layout: Layout = .{ .text = "ab界c\nlast", .head = 6, .columns = 4, .rows = 2 };
    try std.testing.expectEqualDeep([2]u32{ 1, 1 }, layout.position(6));
    try std.testing.expectEqualDeep([2]u32{ 0, 2 }, layout.position(7));
    try std.testing.expectEqual(@as(u32, 2), layout.offset(.{ 2.1, 0 }));
    try std.testing.expectEqual(@as(u32, 5), layout.offset(.{ 0, 1 }));
    const scrolled: Layout = .{ .text = "one\ntwo\nthree", .head = 13, .columns = 8, .rows = 2 };
    try std.testing.expectEqual(@as(u32, 1), scrolled.firstRow());
    try std.testing.expectEqual(@as(u32, 4), scrolled.offset(.{ 0, 0 }));
}

test "proportional composer shares measured word wrapping and grapheme hit positions" {
    const std = @import("std");
    var atlas = try @import("../../text/GlyphAtlas.zig").init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    const font: @import("EditorFont.zig") = .{ .atlas = &atlas, .pixel_height = 16 };
    try font.prepare("WWW iii café e\u{301}");
    try std.testing.expect(font.measure("iii") < font.measure("WWW"));
    const layout: Layout = .{ .text = "WWW iii café", .head = 0, .columns = font.measure("WWW "), .rows = 4, .font = font };
    try std.testing.expectEqualDeep([2]u32{ 0, 1 }, layout.position(4));
    try std.testing.expectEqual(@as(u32, 5), layout.offset(.{ @floatFromInt(font.measure("i")), 1 }));
    const accent: Layout = .{ .text = "e\u{301}é", .head = 0, .columns = 100, .rows = 1, .font = font };
    const end = accent.position(3);
    try std.testing.expectEqual(@as(u32, 3), accent.offset(.{ @floatFromInt(end[0]), 0 }));
    const shapes = atlas.shape_calls;
    const rasters = atlas.raster_attempts;
    for (0..20) |_| {
        _ = layout.position(9);
        _ = layout.offset(.{ 9, 1 });
    }

    try std.testing.expectEqual(shapes, atlas.shape_calls);
    try std.testing.expectEqual(rasters, atlas.raster_attempts);
}

test "a full last line keeps its caret visible and distinct from the next hard line" {
    const std = @import("std");
    const last: Layout = .{ .text = "abcd", .head = 4, .columns = 4, .rows = 1 };
    try std.testing.expectEqualDeep([2]u32{ 4, 0 }, last.position(4));
    try std.testing.expectEqual(@as(u32, 0), last.firstRow());
    const newline: Layout = .{ .text = "abcd\nef", .head = 0, .columns = 4, .rows = 2 };
    try std.testing.expectEqualDeep([2]u32{ 4, 0 }, newline.position(4));
    try std.testing.expectEqualDeep([2]u32{ 0, 1 }, newline.position(5));
    try std.testing.expectEqual(@as(u32, 4), newline.offset(.{ 4, 0 }));
    try std.testing.expectEqual(@as(u32, 5), newline.offset(.{ 0, 1 }));
}

test "shaped editor lines share kerning and internal ligature carets with pointer selection" {
    const std = @import("std");
    var atlas = try @import("../../text/GlyphAtlas.zig").init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    const font: @import("EditorFont.zig") = .{ .atlas = &atlas, .pixel_height = 16 };
    const text = "AV office fi e\u{301}x\nAV office fi";
    try font.prepare(text);
    const layout: Layout = .{ .text = text, .head = 0, .columns = font.measure("AV office "), .rows = 32, .font = font };
    var lines: WrappedLines = .{ .text = text, .width = layout.columns, .font = font };
    while (lines.next()) |line| {
        try std.testing.expectEqual(@as(u32, font.measure(line)), lines.position(line.len));
        try std.testing.expect(lines.position(line.len) <= layout.columns);
    }

    var iterator: core.GraphemeIterator = .{ .bytes = text };
    while (iterator.next()) |_| {
        const position_value = layout.position(@intCast(iterator.index));
        try std.testing.expectEqual(@as(u32, @intCast(iterator.index)), layout.offset(.{ @floatFromInt(position_value[0]), @floatFromInt(position_value[1]) }));
    }
}

test "maximum composer shaped queries keep native allocations discovery and raster work at zero" {
    const std = @import("std");
    var atlas = try @import("../../text/GlyphAtlas.zig").init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    const font: @import("EditorFont.zig") = .{ .atlas = &atlas, .pixel_height = 16 };
    const text = "AV office café " ** 256;
    comptime std.debug.assert(text.len == 4096);
    try font.prepare(text);
    const layout: Layout = .{ .text = text, .head = text.len, .columns = 560, .rows = 4, .font = font };
    _ = layout.position(text.len);
    _ = layout.offset(.{ 40, 2 });
    const shapes = atlas.shape_calls;
    const rasters = atlas.raster_attempts;
    const lookups = atlas.fonts.lookups;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    atlas.allocator = failing.allocator();
    defer atlas.allocator = std.testing.allocator;
    const started = std.Io.Clock.awake.now(std.testing.io);
    for (0..20) |_| {
        const caret = layout.position(text.len);
        try std.testing.expect(caret[1] > 4);
        const offset_value = layout.offset(.{ 40, 2 });
        try std.testing.expect(offset_value <= text.len);
    }

    const elapsed = started.durationTo(std.Io.Clock.awake.now(std.testing.io));
    std.debug.print("\neditor 4KiB position+hit: {d}us/pair; scratch={d} bytes; cache={d} bytes; extra_shapes={d}\n", .{ @divTrunc(elapsed.toMicroseconds(), 20), @sizeOf(WrappedLines), @sizeOf(@import("../../text/EditorShapingCache.zig")), atlas.shape_calls - shapes });
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    try std.testing.expectEqual(rasters, atlas.raster_attempts);
    try std.testing.expectEqual(shapes, atlas.shape_calls);
    try std.testing.expectEqual(lookups, atlas.fonts.lookups);
    try std.testing.expect(@sizeOf(WrappedLines) <= 66 * 1024);
}
