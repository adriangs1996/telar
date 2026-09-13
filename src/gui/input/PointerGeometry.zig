const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Event = @import("../native/InputEvent.zig").InputEvent;
const Geometry = @This();

origin: [2]u32 = .{ 0, 0 },
size: core.TerminalSize = .{ .cols = 0, .rows = 0 },

/// Padding lies outside the grid, never over its first cell. Existing drags
/// clamp there so selection can finish beyond the window. Example: `geometry.resolve(event)`.
pub fn resolve(geometry: Geometry, event: Event) ?client.Mouse {
    if (event.code < 1 or event.code > 6) {
        return null;
    }

    if (geometry.size.cell_width_px == 0 or geometry.size.cell_height_px == 0) {
        return null;
    }

    const x = event.x - @as(f64, @floatFromInt(geometry.origin[0]));
    const y = event.y - @as(f64, @floatFromInt(geometry.origin[1]));
    const width = @as(u32, geometry.size.cols) * geometry.size.cell_width_px;
    const height = @as(u32, geometry.size.rows) * geometry.size.cell_height_px;
    if (width == 0 or height == 0) {
        return null;
    }

    const retained = event.code == 2 or event.code == 3;
    if (!retained and (x < 0 or y < 0 or x >= @as(f64, @floatFromInt(width)) or y >= @as(f64, @floatFromInt(height)))) {
        return null;
    }

    const raw_x: u32 = @intFromFloat(std.math.clamp(x, 0, @as(f64, @floatFromInt(width - 1))));
    const raw_y: u32 = @intFromFloat(std.math.clamp(y, 0, @as(f64, @floatFromInt(height - 1))));
    const kinds = [_]client.Mouse.Kind{ .press, .release, .drag, .scroll_up, .scroll_down, .move };
    return .{
        .x = @intCast(raw_x / geometry.size.cell_width_px),
        .y = @intCast(raw_y / geometry.size.cell_height_px),
        .raw_x = raw_x,
        .raw_y = raw_y,
        .button = @as(u8, switch (event.code) {
            3 => 32 + @as(u8, @intCast(event.button)),
            4 => 64,
            5 => 65,
            6 => 35,
            else => @intCast(event.button),
        }) | (@as(u8, @intCast(event.mods & 7)) << 2),
        .kind = kinds[event.code - 1],
    };
}

test "pointer geometry removes physical padding and clamps only retained gestures" {
    const geometry: Geometry = .{ .origin = .{ 8, 4 }, .size = .{ .cols = 10, .rows = 4, .cell_width_px = 8, .cell_height_px = 16 } };
    try std.testing.expect(geometry.resolve(.{ .kind = 6, .code = 1, .x = 7, .y = 4 }) == null);
    const inside = geometry.resolve(.{ .kind = 6, .code = 1, .x = 24, .y = 20 }).?;
    try std.testing.expectEqual(@as(u16, 2), inside.x);
    try std.testing.expectEqual(@as(u16, 1), inside.y);
    try std.testing.expectEqual(@as(u32, 16), inside.raw_x);
    const outside = geometry.resolve(.{ .kind = 6, .code = 2, .x = -100, .y = 1000 }).?;
    try std.testing.expectEqual(@as(u16, 0), outside.x);
    try std.testing.expectEqual(@as(u16, 3), outside.y);
}

test "pointer normalization retains SGR button modifiers movement and wheel identity" {
    const geometry: Geometry = .{ .size = .{ .cols = 4, .rows = 4, .cell_width_px = 8, .cell_height_px = 16 } };
    const expected = [_]u8{ 28, 28, 60, 92, 93, 63 };
    for (expected, 1..) |button, code| {
        const event = geometry.resolve(.{ .kind = 6, .code = @intCast(code), .mods = 7 }).?;
        try std.testing.expectEqual(button, event.button);
    }
}
