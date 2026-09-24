const assets = @import("assets");
const std = @import("std");
const textraster = @import("textraster");
const Rasterizer = textraster.Rasterizer;
const Surface = textraster.Surface;

test "embedded JetBrains Mono rasterizes UTF-8 into RGBA" {
    var rasterizer = try Rasterizer.initFont(assets.jetbrains_mono);
    defer rasterizer.deinit();
    try rasterizer.setPixelHeight(16);

    var pixels: [256 * 32 * 4]u8 = @splat(0);
    const surface: Surface = .{ .pixels = &pixels, .width = 256, .height = 32 };
    const advance = try rasterizer.drawText(.{
        .surface = surface,
        .origin = .{ .x = 4, .y = 22 },
        .text = "Telar ✓",
        .color = .{ .red = 220, .green = 230, .blue = 240 },
        .max_width = 248,
    });
    try std.testing.expect(advance > 0);
    try std.testing.expectEqual(advance, try rasterizer.measureText("Telar ✓"));
    try std.testing.expect(std.mem.indexOfNone(u8, &pixels, &.{0}) != null);
}

test "HarfBuzz shapes a decomposed grapheme before rasterization" {
    var rasterizer = try Rasterizer.initFont(assets.jetbrains_mono);
    defer rasterizer.deinit();
    try rasterizer.setPixelHeight(16);
    const shaped = try rasterizer.shapeText("e\u{301}");
    try std.testing.expectEqual(@as(usize, 1), shaped.glyphs.len);
}

test "empty notification lines are valid" {
    var rasterizer = try Rasterizer.initFont(assets.jetbrains_mono);
    defer rasterizer.deinit();
    try rasterizer.setPixelHeight(16);
    var pixels: [4]u8 = @splat(0);
    try std.testing.expectEqual(@as(u32, 0), try rasterizer.drawText(.{
        .surface = .{ .pixels = &pixels, .width = 1, .height = 1 },
        .origin = .{ .x = 0, .y = 0 },
        .text = "",
        .color = .{ .red = 255, .green = 255, .blue = 255 },
        .max_width = 1,
    }));
}

test "surface length is checked before rasterization" {
    var rasterizer = try Rasterizer.initFont(assets.jetbrains_mono);
    defer rasterizer.deinit();
    try rasterizer.setPixelHeight(12);
    var pixels: [3]u8 = @splat(0);
    try std.testing.expectError(error.InvalidSurface, rasterizer.drawText(.{
        .surface = .{ .pixels = &pixels, .width = 1, .height = 1 },
        .origin = .{ .x = 0, .y = 0 },
        .text = "x",
        .color = .{ .red = 255, .green = 255, .blue = 255 },
        .max_width = 1,
    }));
}
