//! Resource and continuity proofs for procedural block elements in the atlas.
const std = @import("std");
const Atlas = @import("GlyphAtlas.zig");
const QuadList = @import("../render/QuadList.zig");
const TextRun = @import("TextRun.zig");
const quad = @import("../render/Quad.zig");

fn makeAtlas() !Atlas {
    return Atlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
}

test "block elements never shape rasterize or allocate even cold and fill the configured cell" {
    var atlas = try makeAtlas();
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    try list.reserve(2);
    const version = atlas.version;
    const pixels_hash = std.hash.Wyhash.hash(0, atlas.pixels);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    atlas.allocator = failing.allocator();
    list.allocator = failing.allocator();
    defer {
        atlas.allocator = std.testing.allocator;
        list.allocator = std.testing.allocator;
    }

    for (0x2580..0x25a0) |codepoint| {
        var bytes: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(@intCast(codepoint), &bytes);
        for (0..4) |style| {
            list.clear();
            const advance = try atlas.place(.{ .text = bytes[0..length], .x = 10, .y = 70.5, .color = .white, .pixel_height = 44, .bold = style & 1 != 0, .italic = style & 2 != 0, .cell_bounds = .{ .x = 0, .y = -50.5, .width = 26, .height = 71 } }, &list);
            try std.testing.expectEqual(@as(f32, 26), advance);
            try std.testing.expect(list.items().len >= 1 and list.items().len <= 2);
            for (list.items()) |ink| {
                try std.testing.expectEqual(quad.solid_uv, [_]f32{ ink.u0, ink.v0, ink.u1, ink.v1 });
                try std.testing.expect(ink.x >= 10 and ink.x + ink.width <= 36);
                try std.testing.expect(ink.y >= 20 and ink.y + ink.height <= 91);
            }
        }
    }

    list.clear();
    _ = try atlas.place(.{ .text = "\u{2588}", .x = 10, .y = 70.5, .color = .white, .pixel_height = 44, .cell_bounds = .{ .x = 0, .y = -50.5, .width = 26, .height = 71 } }, &list);
    const full = list.items()[0];
    try std.testing.expectEqual([_]f32{ 10, 20, 26, 71 }, [_]f32{ full.x, full.y, full.width, full.height });
    try std.testing.expectEqual(@as(usize, 0), atlas.shape_calls);
    try std.testing.expectEqual(@as(usize, 0), atlas.raster_attempts);
    try std.testing.expectEqual(@as(usize, 0), atlas.boxes.rasterizations);
    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expectEqual(pixels_hash, std.hash.Wyhash.hash(0, atlas.pixels));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "adjacent block cells and rows meet edge to edge with identical shade quads" {
    var atlas = try makeAtlas();
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    const cell: @import("../render/Rect.zig") = .{ .x = 0, .y = -22, .width = 11, .height = 29 };
    try std.testing.expectEqual(@as(f32, 44), try atlas.place(.{ .text = "\u{2592}\u{2592}\u{2580}\u{2584}", .x = 3, .y = 30, .color = .white, .pixel_height = 16, .cell_bounds = cell }, &list));
    _ = try atlas.place(.{ .text = "\u{2592}\u{2592}\u{2584}\u{2580}", .x = 3, .y = 59, .color = .white, .pixel_height = 16, .cell_bounds = cell }, &list);
    const quads = list.items();
    try std.testing.expectEqual(@as(usize, 8), quads.len);
    try std.testing.expectEqual(@as(f32, 0.5), quads[0].a);
    try std.testing.expectEqual(@as(f32, 0.5), quads[1].a);
    try std.testing.expectEqual(quads[0].x + quads[0].width, quads[1].x);
    try std.testing.expectEqual([_]f32{ quads[0].y, quads[0].width, quads[0].height, quads[0].a }, [_]f32{ quads[1].y, quads[1].width, quads[1].height, quads[1].a });
    try std.testing.expectEqual(quads[0].y + quads[0].height, quads[4].y);
    try std.testing.expectEqual([_]f32{ quads[0].x, quads[0].width, quads[0].height, quads[0].a }, [_]f32{ quads[4].x, quads[4].width, quads[4].height, quads[4].a });
    try std.testing.expectEqual([_]f32{ 25, 8, 11, 15 }, [_]f32{ quads[2].x, quads[2].y, quads[2].width, quads[2].height });
    try std.testing.expectEqual([_]f32{ 36, 23, 11, 14 }, [_]f32{ quads[3].x, quads[3].y, quads[3].width, quads[3].height });
    try std.testing.expectEqual([_]f32{ 25, 52, 11, 14 }, [_]f32{ quads[6].x, quads[6].y, quads[6].width, quads[6].height });
    try std.testing.expectEqual([_]f32{ 36, 37, 11, 15 }, [_]f32{ quads[7].x, quads[7].y, quads[7].width, quads[7].height });
    try std.testing.expectEqual(quads[3].y + quads[3].height, quads[7].y);
}

test "mixed text retains contextual shaping around procedural block elements" {
    var atlas = try makeAtlas();
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    var run: TextRun = .{ .text = "office\u{2588}e\u{301}ffi", .x = 3.5, .y = 20.25, .color = .white, .pixel_height = 16, .cell_bounds = .{ .x = 0, .y = -17.25, .width = 12, .height = 27 } };
    const advance = try atlas.place(run, &list);
    try std.testing.expectEqual(advance, try atlas.measure(run));
    run.text = "office";
    const before = try atlas.measure(run);
    run.text = "e\u{301}ffi";
    const after = try atlas.measure(run);
    try std.testing.expectEqual(before + 12 + after, advance);
    var block: ?quad.Quad = null;
    for (list.items()) |item| {
        if (item.width == 12 and item.height == 27) {
            block = item;
        }
    }

    try std.testing.expectEqual([_]f32{ 3.5 + before, 3 }, [_]f32{ block.?.x, block.?.y });
}

test "block elements use natural metrics when callers omit cell bounds" {
    var atlas = try makeAtlas();
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    const run: TextRun = .{ .text = "\u{2588}", .x = 0, .y = 0, .color = .white, .pixel_height = 32 };
    const advance = try atlas.place(run, &list);
    const size = try atlas.fonts.primary.sized(32);
    try std.testing.expectEqual(@as(f32, @floatFromInt(size.maxAdvance())), advance);
    try std.testing.expectEqual(@as(usize, 1), list.items().len);
    try std.testing.expectEqual(@as(f32, @floatFromInt(size.lineHeight())), list.items()[0].height);
    try std.testing.expectEqual(@as(f32, @floatFromInt(-size.ascender())), list.items()[0].y);
}
