//! Turns the client's cell colors into shader colors. A cell color may defer
//! to the host; the window is its own host, so `default` resolves to the
//! fallback the caller names.
const CoreColor = @import("telar-core").Color;
const Color = @import("Color.zig");

/// Resolves a palette entry. Example: `const bg = cell_colors.resolve(palette.panel_bg, Color.black);`
pub fn resolve(color: CoreColor, fallback: Color) Color {
    return switch (color) {
        .default => fallback,
        .rgb => |rgb| Color.rgb(rgb[0], rgb[1], rgb[2]),
        .indexed => |index| indexed(index),
    };
}

/// The xterm 256-color table: 16 named colors, a 6x6x6 cube, then 24 grays.
fn indexed(index: u8) Color {
    if (index < 16) {
        const named = ansi[index];
        return Color.rgb(named[0], named[1], named[2]);
    }

    if (index < 232) {
        const cube = index - 16;
        return Color.rgb(cubeLevel(cube / 36), cubeLevel((cube / 6) % 6), cubeLevel(cube % 6));
    }

    const gray: u8 = 8 + (index - 232) * 10;
    return Color.rgb(gray, gray, gray);
}

fn cubeLevel(step: u8) u8 {
    return if (step == 0) 0 else 55 + step * 40;
}

const ansi = [16][3]u8{
    .{ 0, 0, 0 },       .{ 205, 49, 49 },   .{ 13, 188, 121 }, .{ 229, 229, 16 },
    .{ 36, 114, 200 },  .{ 188, 63, 188 },  .{ 17, 168, 205 }, .{ 229, 229, 229 },
    .{ 102, 102, 102 }, .{ 241, 76, 76 },   .{ 35, 209, 139 }, .{ 245, 245, 67 },
    .{ 59, 142, 234 },  .{ 214, 112, 214 }, .{ 41, 184, 219 }, .{ 255, 255, 255 },
};

test "default defers to the fallback and rgb passes through" {
    const std = @import("std");
    const fallback = Color.rgb(1, 2, 3);
    try std.testing.expectEqual(Color.black, resolve(.default, Color.black));
    try std.testing.expectEqual(Color.rgb(9, 8, 7), resolve(.{ .rgb = .{ 9, 8, 7 } }, fallback));
}

test "indexed colors follow the xterm cube and gray ramp" {
    const std = @import("std");
    try std.testing.expectEqual(Color.rgb(0, 0, 0), resolve(.{ .indexed = 16 }, Color.white));
    try std.testing.expectEqual(Color.rgb(255, 255, 255), resolve(.{ .indexed = 231 }, Color.black));
    try std.testing.expectEqual(Color.rgb(95, 135, 0), resolve(.{ .indexed = 64 }, Color.black));
    try std.testing.expectEqual(Color.rgb(8, 8, 8), resolve(.{ .indexed = 232 }, Color.black));
    try std.testing.expectEqual(Color.rgb(238, 238, 238), resolve(.{ .indexed = 255 }, Color.black));
}
