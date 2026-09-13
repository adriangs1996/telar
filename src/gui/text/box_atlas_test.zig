//! Resource ownership and fallback proofs for procedural box glyphs.
const std = @import("std");
const Atlas = @import("GlyphAtlas.zig");
const Cache = @import("BoxCache.zig");
const QuadList = @import("../render/QuadList.zig");
const TextRun = @import("TextRun.zig");

fn makeAtlas() !Atlas {
    return Atlas.init(std.testing.allocator, .{ .font = @import("assets").jetbrains_mono, .pixel_height = 16 });
}

test "box mask identities include geometry and stroke but exclude position color and font slant" {
    var atlas = try makeAtlas();
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    var run: TextRun = .{ .text = "╭", .x = 0, .y = 21, .color = .white, .pixel_height = 16, .cell_bounds = .{ .x = 0, .y = -21, .width = 11, .height = 29 } };
    _ = try atlas.place(run, &list);
    const original = list.items()[0];
    const rasters = atlas.boxes.rasterizations;
    for (0..4) |style| {
        list.clear();
        run.x = 12;
        run.y = 51;
        run.color = .black;
        run.bold = style & 1 != 0;
        run.italic = style & 2 != 0;
        _ = try atlas.place(run, &list);
        try std.testing.expectEqual(original.u0, list.items()[0].u0);
        try std.testing.expectEqual(original.v0, list.items()[0].v0);
        try std.testing.expectEqual(rasters, atlas.boxes.rasterizations);
    }

    run.cell_bounds.?.height = 30;
    list.clear();
    _ = try atlas.place(run, &list);
    try std.testing.expectEqual(rasters + 1, atlas.boxes.rasterizations);
    const taller = list.items()[0];
    try std.testing.expect(original.u0 != taller.u0 or original.v0 != taller.v0);
    run.pixel_height = 64;
    list.clear();
    _ = try atlas.place(run, &list);
    try std.testing.expectEqual(rasters + 2, atlas.boxes.rasterizations);
    const heavier = list.items()[0];
    try std.testing.expect(taller.u0 != heavier.u0 or taller.v0 != heavier.v0);
    try std.testing.expectEqual(@as(usize, 0), atlas.shape_calls);
    try std.testing.expectEqual(@as(usize, 0), atlas.raster_attempts);
}

test "full box cache preserves retained masks and uses bounded emergency masks without allocations" {
    var atlas = try makeAtlas();
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    try list.reserve(1);
    var run: TextRun = .{ .text = "╭", .x = 0, .y = 0, .color = .white, .pixel_height = 16, .cell_bounds = .{ .x = 0, .y = 0, .width = 8, .height = 17 } };
    _ = try atlas.place(run, &list);
    const original = list.items()[0];
    for (1..Cache.capacity) |index| {
        run.cell_bounds.?.height = 17 + @as(f32, @floatFromInt(index));
        list.clear();
        _ = try atlas.place(run, &list);
    }

    try std.testing.expectEqual(Cache.capacity, atlas.boxes.count);
    const version = atlas.version;
    const rasters = atlas.boxes.rasterizations;
    const shelf = [3]u32{ atlas.shelf_x, atlas.shelf_y, atlas.shelf_height };
    const pixels_hash = std.hash.Wyhash.hash(0, atlas.pixels);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    atlas.allocator = failing.allocator();
    list.allocator = failing.allocator();
    defer {
        atlas.allocator = std.testing.allocator;
        list.allocator = std.testing.allocator;
    }

    for (0..200) |index| {
        run.cell_bounds.?.height = 100 + @as(f32, @floatFromInt(index));
        list.clear();
        _ = try atlas.place(run, &list);
        try std.testing.expectEqual(atlas.boxes.fallback[0].u0, list.items()[0].u0);
        try std.testing.expectEqual(atlas.boxes.fallback[0].v0, list.items()[0].v0);
    }

    run.cell_bounds.?.height = 17;
    list.clear();
    _ = try atlas.place(run, &list);
    try std.testing.expectEqualDeep(original, list.items()[0]);
    try std.testing.expectEqual(version, atlas.version);
    try std.testing.expectEqual(rasters, atlas.boxes.rasterizations);
    try std.testing.expectEqual(shelf, [3]u32{ atlas.shelf_x, atlas.shelf_y, atlas.shelf_height });
    try std.testing.expectEqual(pixels_hash, std.hash.Wyhash.hash(0, atlas.pixels));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "full atlas and extreme cells cannot retry failed box rasterizations or corrupt reserved masks" {
    var atlas = try makeAtlas();
    defer atlas.deinit();
    var list = QuadList.init(std.testing.allocator);
    defer list.deinit();
    try list.reserve(1);
    atlas.shelf_y = Atlas.side;
    const pixels_hash = std.hash.Wyhash.hash(0, atlas.pixels);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    atlas.allocator = failing.allocator();
    list.allocator = failing.allocator();
    defer {
        atlas.allocator = std.testing.allocator;
        list.allocator = std.testing.allocator;
    }

    for ([_]f32{ 71, 256, 257, 65535 }) |height| {
        for (0..7) |shape| {
            var bytes: [4]u8 = undefined;
            const length = try std.unicode.utf8Encode(@intCast(0x256d + shape), &bytes);
            const run: TextRun = .{ .text = bytes[0..length], .x = 0, .y = 0, .color = .white, .pixel_height = 44, .cell_bounds = .{ .x = 0, .y = 0, .width = 26, .height = height } };
            for (0..120) |_| {
                list.clear();
                _ = try atlas.place(run, &list);
                try std.testing.expectEqual(atlas.boxes.fallback[shape].u0, list.items()[0].u0);
                try std.testing.expectEqual(atlas.boxes.fallback[shape].v0, list.items()[0].v0);
            }
        }
    }

    try std.testing.expectEqual(@as(u32, 1), atlas.version);
    try std.testing.expectEqual(@as(usize, 0), atlas.boxes.rasterizations);
    try std.testing.expectEqual(@as(usize, 28), atlas.boxes.count);
    try std.testing.expectEqual(pixels_hash, std.hash.Wyhash.hash(0, atlas.pixels));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}
