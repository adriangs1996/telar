//! Reusable client-side text rasterization backed by embedded JetBrains Mono.
//!
//! The rasterizer owns FreeType's mutable face and is therefore intentionally
//! single-threaded. Callers own the destination buffer and the media-path
//! scheduling around it.

const std = @import("std");
const ft = @import("freetype").c;

pub const embedded_font: []const u8 = @embedFile("../assets/JetBrainsMono-Regular.ttf");

pub const Color = @import("Color.zig");

pub const Surface = @import("Surface.zig");

pub const Point = @import("RasterizerPoint.zig");

pub const TextDraw = @import("TextDraw.zig");

const BitmapBlend = @import("BitmapBlend.zig");

const PixelBlend = @import("PixelBlend.zig");

pub const Metrics = @import("Metrics.zig");

pub const Rasterizer = @import("Rasterizer.zig");

pub fn fixed26_6Round(value: anytype) i32 {
    const signed: i64 = @intCast(value);
    return @intCast(if (signed >= 0) (signed + 32) >> 6 else -(((-signed) + 32) >> 6));
}

pub fn blendBitmap(blend: BitmapBlend) !void {
    if (blend.bitmap.pixel_mode != ft.FT_PIXEL_MODE_GRAY and
        blend.bitmap.pixel_mode != ft.FT_PIXEL_MODE_MONO)
    {
        return error.UnsupportedPixelMode;
    }
    if (blend.bitmap.buffer == null) {
        return;
    }
    const rows: usize = @intCast(blend.bitmap.rows);
    const columns: usize = @intCast(blend.bitmap.width);
    const pitch: i32 = blend.bitmap.pitch;
    const absolute_pitch: usize = @intCast(@abs(pitch));
    const source = blend.bitmap.buffer[0 .. absolute_pitch * rows];

    for (0..rows) |source_y| {
        const target_y = blend.destination.y + @as(i32, @intCast(source_y));
        if (target_y < 0 or target_y >= blend.surface.height) {
            continue;
        }
        const physical_y = if (pitch >= 0) source_y else rows - 1 - source_y;
        const source_row = source[physical_y * absolute_pitch ..][0..absolute_pitch];
        for (0..columns) |source_x| {
            const target_x = blend.destination.x + @as(i32, @intCast(source_x));
            if (target_x < 0 or target_x >= blend.surface.width) {
                continue;
            }
            const coverage: u8 = if (blend.bitmap.pixel_mode == ft.FT_PIXEL_MODE_GRAY)
                source_row[source_x]
            else if (source_row[source_x / 8] & (@as(u8, 0x80) >> @intCast(source_x % 8)) != 0)
                255
            else
                0;
            if (coverage == 0) {
                continue;
            }
            const alpha: u8 = @intCast((@as(u16, coverage) * blend.color.alpha + 127) / 255);
            blendPixel(blend.surface, .{
                .point = .{ .x = @intCast(target_x), .y = @intCast(target_y) },
                .color = blend.color,
                .alpha = alpha,
            });
        }
    }
}

fn blendPixel(surface: Surface, blend: PixelBlend) void {
    const index = (@as(usize, blend.point.y) * surface.width + blend.point.x) * 4;
    // KGP consumes straight RGBA. Weight destination RGB by its alpha too,
    // otherwise glyphs drawn onto transparency acquire dark fringes.
    const previous_weight: u32 = @as(u32, surface.pixels[index + 3]) * (255 - @as(u32, blend.alpha));
    const next_weight: u32 = @as(u32, blend.alpha) * 255;
    const total = previous_weight + next_weight;
    if (total == 0) {
        return;
    }

    const color = [3]u8{ blend.color.red, blend.color.green, blend.color.blue };
    for (color, 0..) |channel, offset| {
        surface.pixels[index + offset] = @intCast((@as(u32, surface.pixels[index + offset]) * previous_weight +
            @as(u32, channel) * next_weight + total / 2) / total);
    }

    surface.pixels[index + 3] = @intCast((total + 127) / 255);
}

test "embedded JetBrains Mono rasterizes UTF-8 into RGBA" {
    var rasterizer = try Rasterizer.init();
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
    var rasterizer = try Rasterizer.init();
    defer rasterizer.deinit();
    try rasterizer.setPixelHeight(16);
    const shaped = try rasterizer.shapeText("e\u{301}");
    try std.testing.expectEqual(@as(usize, 1), shaped.glyphs.len);
}

test "empty notification lines are valid" {
    var rasterizer = try Rasterizer.init();
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

test "transparent glyphs retain straight RGB and opaque blending stays unchanged" {
    var pixels: [4]u8 = .{ 0, 0, 0, 0 };
    const surface: Surface = .{ .pixels = &pixels, .width = 1, .height = 1 };
    const blend: PixelBlend = .{
        .point = .{ .x = 0, .y = 0 },
        .color = .{ .red = 240, .green = 180, .blue = 120 },
        .alpha = 64,
    };
    blendPixel(surface, blend);
    try std.testing.expectEqualSlices(u8, &.{ 240, 180, 120, 64 }, &pixels);
    pixels = .{ 20, 40, 60, 255 };
    blendPixel(surface, blend);
    try std.testing.expectEqualSlices(u8, &.{ 75, 75, 75, 255 }, &pixels);
}

test "surface length is checked before rasterization" {
    var rasterizer = try Rasterizer.init();
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
