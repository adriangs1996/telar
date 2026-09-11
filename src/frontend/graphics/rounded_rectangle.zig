//! Shared antialiased RGBA fill for client-owned rounded backgrounds.

const Input = @import("Input.zig");
const std = @import("std");
const Shape = @import("Shape.zig");
const RoundedRectanglePoint = @import("RoundedRectanglePoint.zig");

/// Fills a quota-validated surface. Transparent corners retain the fill RGB
/// so hosts can interpolate the alpha edge without dark fringes.
///
/// ```zig
/// rounded.render(.{ .pixels = pixels, .shape = shape, .color = color });
/// ```
pub fn render(input: Input) void {
    const width = input.shape.size.width;
    const height = input.shape.size.height;
    const stride = input.stride orelse width;
    std.debug.assert(width <= stride);
    std.debug.assert((@as(u64, height -| 1) * stride + width) * 4 <= input.pixels.len);
    const shape: Shape = .{ .size = input.shape.size, .radius = @min(input.shape.radius, @min(width, height) / 2) };
    var y: u32 = 0;

    while (y < height) : (y += 1) {
        var x: u32 = 0;

        while (x < width) : (x += 1) {
            const index = (@as(usize, y) * stride + x) * 4;
            input.pixels[index..][0..4].* = .{ input.color[0], input.color[1], input.color[2], coverage(.{ .x = x, .y = y }, shape) };
        }
    }
}

fn coverage(point: RoundedRectanglePoint, shape: Shape) u8 {
    if (shape.radius == 0) {
        return 255;
    }

    const supersample: u32 = 4;
    const units_per_pixel: u32 = supersample * 2;
    const sampled_shape: Shape = .{
        .size = .{ .width = shape.size.width * units_per_pixel, .height = shape.size.height * units_per_pixel },
        .radius = shape.radius * units_per_pixel,
    };
    var inside: u32 = 0;

    for (0..supersample) |sample_y| {
        for (0..supersample) |sample_x| {
            const sampled: RoundedRectanglePoint = .{
                .x = point.x * units_per_pixel + @as(u32, @intCast(sample_x * 2 + 1)),
                .y = point.y * units_per_pixel + @as(u32, @intCast(sample_y * 2 + 1)),
            };
            inside += @intFromBool(contains(sampled, sampled_shape));
        }
    }

    return @intCast((inside * 255 + supersample * supersample / 2) / (supersample * supersample));
}

fn contains(point: RoundedRectanglePoint, shape: Shape) bool {
    if ((point.x >= shape.radius and point.x <= shape.size.width - shape.radius) or
        (point.y >= shape.radius and point.y <= shape.size.height - shape.radius))
    {
        return true;
    }

    const center_x = if (point.x < shape.radius) shape.radius else shape.size.width - shape.radius;
    const center_y = if (point.y < shape.radius) shape.radius else shape.size.height - shape.radius;
    const delta_x = @as(i64, point.x) - center_x;
    const delta_y = @as(i64, point.y) - center_y;
    return delta_x * delta_x + delta_y * delta_y <= @as(i64, shape.radius) * shape.radius;
}

test "rounded subrect fill preserves neighbouring pixels and row stride" {
    var pixels: [24 * 20 * 4]u8 = @splat(17);
    render(.{
        .pixels = pixels[4 * 4 ..],
        .shape = .{ .size = .{ .width = 16, .height = 20 }, .radius = 8 },
        .color = .{ 12, 34, 56 },
        .stride = 24,
    });
    for (0..20) |y| {
        for (0..24) |x| {
            const pixel = pixels[(y * 24 + x) * 4 ..][0..4];
            if (x < 4 or x >= 20) {
                try std.testing.expectEqualSlices(u8, &.{ 17, 17, 17, 17 }, pixel);
            } else {
                try std.testing.expectEqualSlices(u8, &.{ 12, 34, 56 }, pixel[0..3]);
            }
        }
    }
}

test "rounded fill has transparent corners opaque center and symmetric alpha" {
    var pixels: [24 * 20 * 4]u8 = undefined;
    render(.{ .pixels = &pixels, .shape = .{ .size = .{ .width = 24, .height = 20 }, .radius = 10 }, .color = .{ 12, 34, 56 } });
    try std.testing.expectEqual(@as(u8, 0), pixels[3]);
    try std.testing.expectEqual(@as(u8, 255), pixels[(10 * 24 + 12) * 4 + 3]);

    for (0..20) |y| {
        for (0..24) |x| {
            try std.testing.expectEqual(pixels[(y * 24 + x) * 4 + 3], pixels[(y * 24 + 23 - x) * 4 + 3]);
        }
    }
}
