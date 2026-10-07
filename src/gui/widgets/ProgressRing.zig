//! A circular progress stroke composed from bounded, antialiased round quads.
const cellgrid = @import("cellgrid");
const std = @import("std");
const Canvas = @import("Canvas.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const ProgressRing = @This();

pub const segments = 64;
const circle = points();

area: Rect,
color: cellgrid.Color,
fraction: f32,
/// Turns clockwise from twelve o'clock.
rotation: f32 = 0,

/// Draws a track and round-ended arc without creating textures or font glyphs.
/// Example: `try (ProgressRing{ .area = square, .color = accent, .fraction = 0.42 }).draw(canvas);`
pub fn draw(self: ProgressRing, canvas: *Canvas) !void {
    const side = @min(self.area.width, self.area.height);
    if (side <= 0) {
        return;
    }

    const stroke = @min(side / 4, @max(1, side * 0.12));
    const bounds: Rect = .{ .x = self.area.x + (self.area.width - side) / 2, .y = self.area.y + (self.area.height - side) / 2, .width = side, .height = side };
    try canvas.ringAt(bounds, .{ .width = stroke, .radius = side / 2, .color = self.color, .alpha = 0.18 });
    const fraction = std.math.clamp(self.fraction, 0, 1);
    if (fraction == 0) {
        return;
    }

    const radius = (side - stroke) / 2;
    const angle = self.rotation * (2 * std.math.pi);
    const cosine = @cos(angle);
    const sine = @sin(angle);
    const steps: usize = @intFromFloat(@ceil(fraction * segments));
    for (0..steps + 1) |index| {
        const point = if (index == steps) endpoint(fraction) else circle[index];
        const x = point[0] * cosine - point[1] * sine;
        const y = point[0] * sine + point[1] * cosine;
        try canvas.fillRoundedAt(.{ .x = bounds.x + radius + x * radius, .y = bounds.y + radius + y * radius, .width = stroke, .height = stroke }, .{ .radius = stroke / 2, .color = self.color });
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
