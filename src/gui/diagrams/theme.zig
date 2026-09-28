//! Resolves the colors a rendered diagram takes from the active theme.
const data = @import("model");
const mermaid = @import("mermaid");
const colors = @import("../render/cell_colors.zig");
const gfx = @import("gfx");
const Color = gfx.Color;

/// Maps the palette's surface, text and accent over the terminal colors.
/// Example: `const theme = diagram_theme.resolve(canvas.theme);`
pub fn resolve(theme: data.ColorTheme) mermaid.Theme {
    const background = theme.terminal.background;
    const foreground = theme.terminal.foreground;
    return .{
        .bg = rgb(colors.withPalette(theme.palette.surface0, Color.rgb(background[0], background[1], background[2]), &theme.terminal.palette)),
        .fg = rgb(colors.withPalette(theme.palette.text, Color.rgb(foreground[0], foreground[1], foreground[2]), &theme.terminal.palette)),
        .accent = rgb(colors.withPalette(theme.palette.accent, Color.rgb(foreground[0], foreground[1], foreground[2]), &theme.terminal.palette)),
    };
}

fn rgb(color: Color) [3]u8 {
    return .{ @intFromFloat(@round(color.r * 255)), @intFromFloat(@round(color.g * 255)), @intFromFloat(@round(color.b * 255)) };
}

test "diagram colors keep text and accent distinguishable from the surface" {
    const std = @import("std");
    const resolved = resolve(data.theme_support.default_theme);
    try std.testing.expect(!std.meta.eql(resolved.bg, resolved.fg));
    try std.testing.expect(!std.meta.eql(resolved.bg, resolved.accent));
}
