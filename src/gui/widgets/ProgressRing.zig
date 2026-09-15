//! A circular progress stroke composed from bounded, antialiased round quads.
const std = @import("std");
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const ProgressRing = @This();

pub const segments = 64;
const circle = points();

area: Rect,
color: core.Color,
fraction: f32,
/// Turns clockwise from twelve o'clock.
rotation: f32 = 0,

/// Draws a track and round-ended arc without creating textures or font glyphs.
/// Example: `try (ProgressRing{ .area = square, .color = accent, .fraction = 0.42 }).draw(canvas);`
pub fn draw(ring: ProgressRing, canvas: *Canvas) !void {
    const side = @min(ring.area.width, ring.area.height);
    if (side <= 0) {
        return;
    }

    const stroke = @min(side / 4, @max(1, side * 0.12));
    const bounds: Rect = .{ .x = ring.area.x + (ring.area.width - side) / 2, .y = ring.area.y + (ring.area.height - side) / 2, .width = side, .height = side };
    try canvas.ringAt(bounds, .{ .width = stroke, .radius = side / 2, .color = ring.color, .alpha = 0.18 });
    const fraction = std.math.clamp(ring.fraction, 0, 1);
    if (fraction == 0) {
        return;
    }

    const radius = (side - stroke) / 2;
    const angle = ring.rotation * (2 * std.math.pi);
    const cosine = @cos(angle);
    const sine = @sin(angle);
    const steps: usize = @intFromFloat(@ceil(fraction * segments));
    for (0..steps + 1) |index| {
        const point = if (index == steps) endpoint(fraction) else circle[index];
        const x = point[0] * cosine - point[1] * sine;
        const y = point[0] * sine + point[1] * cosine;
        try canvas.fillRoundedAt(.{ .x = bounds.x + radius + x * radius, .y = bounds.y + radius + y * radius, .width = stroke, .height = stroke }, .{ .radius = stroke / 2, .color = ring.color });
    }
}

fn endpoint(fraction: f32) [2]f32 {
    const angle = fraction * (2 * std.math.pi);
    return .{ @sin(angle), -@cos(angle) };
}

fn points() [segments][2]f32 {
    @setEvalBranchQuota(10000);
    var values: [segments][2]f32 = undefined;
    for (&values, 0..) |*point, index| {
        point.* = endpoint(@as(f32, @floatFromInt(index)) / segments);
    }

    return values;
}

test "progress arcs stay bounded at every fraction scale and rotation without allocating" {
    var quads = @import("../render/QuadList.zig").init(std.testing.allocator);
    defer quads.deinit();
    try quads.reserve(segments + 2);
    var canvas: Canvas = .{ .atlas = undefined, .quads = &quads, .metrics = .{ .cell_width = 10, .cell_height = 20, .pixel_height = 16, .baseline = 15 }, .origin = .{ 0, 0 }, .theme = @import("telar-client").theme_support.default_theme };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    quads.allocator = failing.allocator();
    defer quads.allocator = std.testing.allocator;
    for ([_]f32{ 1, 14, 28, 56 }) |side| {
        const bounds: Rect = .{ .x = 12, .y = 19, .width = side, .height = side };
        for ([_]f32{ 0, 0.001, 0.25, 0.73, 1 }) |fraction| {
            for ([_]f32{ 0, 0.173, 0.5, 0.92 }) |rotation| {
                quads.clear();
                try (ProgressRing{ .area = bounds, .color = .{ .rgb = .{ 255, 0, 0 } }, .fraction = fraction, .rotation = rotation }).draw(&canvas);
                try std.testing.expect(quads.items().len <= segments + 2);
                try std.testing.expectEqual(@as(f32, 0.18), quads.items()[0].border_a);
                for (quads.items()) |item| {
                    try std.testing.expect(item.x >= bounds.x - 0.001 and item.y >= bounds.y - 0.001);
                    try std.testing.expect(item.x + item.width <= bounds.x + side + 0.001);
                    try std.testing.expect(item.y + item.height <= bounds.y + side + 0.001);
                }
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}
