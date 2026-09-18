//! Resolved colors passed as data to the isolated diagram renderer.
const client = @import("telar-client");
const colors = @import("../render/cell_colors.zig");
const Color = @import("../render/Color.zig");
const Theme = @This();

bg: [3]u8,
fg: [3]u8,
accent: [3]u8,

/// Example: `const theme = Theme.init(canvas.theme);`
pub fn init(theme: client.ColorTheme) Theme {
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
