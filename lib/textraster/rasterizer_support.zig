//! FreeType bitmap blending into straight-alpha RGBA surfaces and the 26.6
//! fixed-point rounding the rasterizer measures with.

const RasterizerPoint = @import("RasterizerPoint.zig");
const Color = @import("Color.zig");
const freetype = @import("freetype");
const Surface = @import("Surface.zig");

pub fn fixed26_6Round(value: anytype) i32 {
    const signed: i64 = @intCast(value);
    return @intCast(if (signed >= 0) (signed + 32) >> 6 else -(((-signed) + 32) >> 6));
}

pub fn blendBitmap(blend: BitmapBlend) !void {
    if (blend.bitmap.pixel_mode != freetype.c.FT_PIXEL_MODE_GRAY and
        blend.bitmap.pixel_mode != freetype.c.FT_PIXEL_MODE_MONO)
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
            const coverage: u8 = if (blend.bitmap.pixel_mode == freetype.c.FT_PIXEL_MODE_GRAY)
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

const BitmapBlend = struct {
    surface: Surface,
    bitmap: freetype.c.FT_Bitmap,
    destination: RasterizerPoint,
    color: Color,
};

const PixelBlend = struct {
    point: struct { x: u32, y: u32 },
    color: Color,
    alpha: u8,
};
