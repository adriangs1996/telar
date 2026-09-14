const std = @import("std");
const builtin = @import("builtin");
const freetype = @import("freetype");
const Atlas = @import("../text/GlyphAtlas.zig");
const MacRasterizer = @import("../text/MacRasterizer.zig");
const QuadList = @import("../render/QuadList.zig");
const TextRun = @import("../text/TextRun.zig");
const font = @import("assets").jetbrains_mono;

test "macOS optical weight controls alpha coverage without writing outside the reserved glyph" {
    if (builtin.os.tag != .macos) {
        return error.SkipZigTest;
    }

    var atlas = try Atlas.init(std.testing.allocator, .{ .font = font, .pixel_height = 36 });
    defer atlas.deinit();
    const index = freetype.c.FT_Get_Char_Index(atlas.fonts.primary.face, 'F');
    var pixels: [64 * 64]u8 = undefined;
    var coverage: [3][4]u64 = .{.{0} ** 4} ** 3;
    for (0..3) |mode| {
        var rasterizer = try MacRasterizer.init(.{
            .font = font.ptr,
            .font_len = font.len,
            .postscript = null,
            .face_index = 0,
            .pixels = &pixels,
            .side = 64,
            .thicken = @intFromBool(mode != 0),
            .strength = if (mode == 1) 0 else 255,
        });
        defer rasterizer.deinit();
        try rasterizer.select(36);
        try std.testing.expectError(error.NativeGlyphMeasureFailed, rasterizer.measure(.{ .index = 65536, .style = 0 }));
        for (0..4) |style| {
            @memset(&pixels, 37);
            var glyph = try rasterizer.measure(.{ .index = index, .style = @intCast(style) });
            glyph.x = 5;
            glyph.y = 6;
            rasterizer.draw(glyph);
            for (pixels, 0..) |alpha, offset| {
                const x = offset % 64;
                const y = offset / 64;
                if (x >= glyph.x and x < glyph.x + glyph.width and y >= glyph.y and y < glyph.y + glyph.height) {
                    coverage[mode][style] += alpha;
                } else {
                    try std.testing.expectEqual(@as(u8, 37), alpha);
                }
            }

            try std.testing.expect(coverage[mode][style] > 0);
            const digest = std.hash.Wyhash.hash(0, &pixels);
            rasterizer.draw(glyph);
            try std.testing.expectEqual(digest, std.hash.Wyhash.hash(0, &pixels));
        }
    }

    for (0..4) |style| {
        // CoreGraphics can bypass optical smoothing in fill-and-stroke mode.
        if (style & 1 == 0) {
            try std.testing.expect(coverage[1][style] > coverage[0][style]);
            try std.testing.expect(coverage[2][style] > coverage[1][style]);
        } else {
            try std.testing.expect(coverage[2][style] >= coverage[0][style]);
        }
    }
    try std.testing.expect(coverage[2][1] > coverage[2][0]);
}

test "font thickening preserves shaping and cell metrics and cached glyphs allocate no adapter storage" {
    var metrics: [3]i64 = undefined;
    var advance: f32 = undefined;
    var digest: u64 = undefined;
    for (0..3) |mode| {
        var atlas = try Atlas.init(std.testing.allocator, .{ .font = font, .pixel_height = 36, .thicken = mode != 0, .thicken_strength = if (mode == 1) 0 else 255 });
        defer atlas.deinit();
        try std.testing.expectEqual(builtin.os.tag == .macos and mode != 0, atlas.fonts.primary.mac_rasterizer != null);
        const current = [3]i64{ try atlas.cellWidth(atlas.pixel_height), try atlas.lineHeight(atlas.pixel_height), try atlas.ascender(atlas.pixel_height) };
        if (mode == 0) {
            metrics = current;
        } else {
            try std.testing.expectEqual(metrics, current);
        }

        var list = QuadList.init(std.testing.allocator);
        defer list.deinit();
        var run: TextRun = .{ .text = "F café e\u{301} ->", .x = 0, .y = 36, .pixel_height = 36, .color = .white };
        for (0..4) |style| {
            list.clear();
            run.bold = style & 1 != 0;
            run.italic = style & 2 != 0;
            const placed = try atlas.place(run, &list);
            if (mode == 0 and style == 0) {
                advance = placed;
            } else {
                try std.testing.expectEqual(advance, placed);
            }

            try std.testing.expect(list.items().len > 0);
        }

        try std.testing.expectEqual(@as(u8, 255), atlas.pixels[0]);
        try std.testing.expectEqual(@as(u8, 255), atlas.pixels[Atlas.side + 1]);
        if (mode == 0) {
            digest = std.hash.Wyhash.hash(0, atlas.pixels);
        } else if (builtin.os.tag != .macos) {
            try std.testing.expectEqual(digest, std.hash.Wyhash.hash(0, atlas.pixels));
        }

        const version = atlas.version;
        const calls = atlas.shape_calls;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        atlas.allocator = failing.allocator();
        list.allocator = failing.allocator();
        defer {
            atlas.allocator = std.testing.allocator;
            list.allocator = std.testing.allocator;
        }

        for (0..4) |style| {
            list.clear();
            run.bold = style & 1 != 0;
            run.italic = style & 2 != 0;
            _ = try atlas.place(run, &list);
        }

        try std.testing.expectEqual(version, atlas.version);
        try std.testing.expectEqual(calls, atlas.shape_calls);
        try std.testing.expect(!failing.has_induced_failure);
    }
}
