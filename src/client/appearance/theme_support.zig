//! A preset owns chrome roles and native terminal colors. TUI panes and gaps
//! retain their host's defaults; child truecolor remains application-owned.

const ThemeType = @import("Theme.zig");
const ColorType = @import("telar-core").Color;
const std = @import("std");

pub const Builtin = enum {
    osaka_jade,
    vesper,
    catppuccin,
    tokyo_night,
    terminal,

    pub fn canonicalName(value: Builtin) []const u8 {
        return switch (value) {
            .osaka_jade => "osaka-jade",
            .vesper => "vesper",
            .catppuccin => "catppuccin",
            .tokyo_night => "tokyo-night",
            .terminal => "terminal",
        };
    }
};

pub const Palette = @import("Palette.zig");

pub const Overrides = @import("Overrides.zig");

pub const Theme = @import("Theme.zig");

pub const default_theme = builtin(.osaka_jade);

pub fn fromName(name: []const u8) ?ThemeType {
    if (eql(name, "osaka-jade") or eql(name, "osaka_jade") or eql(name, "osakajade")) {
        return builtin(.osaka_jade);
    }
    if (eql(name, "vesper")) {
        return builtin(.vesper);
    }
    if (eql(name, "catppuccin") or eql(name, "catppuccin-mocha") or eql(name, "mocha")) {
        return builtin(.catppuccin);
    }
    if (eql(name, "tokyo-night") or eql(name, "tokyonight") or eql(name, "tokyo_night")) {
        return builtin(.tokyo_night);
    }
    if (eql(name, "terminal") or eql(name, "default")) {
        return builtin(.terminal);
    }
    return null;
}

pub fn builtin(name: Builtin) ThemeType {
    return .{
        .base = name,
        .terminal = terminal(name),
        .palette = switch (name) {
            .osaka_jade => .{
                .accent = rgb24c(0xa8c98c),
                .panel_bg = .default,
                .surface0 = rgb24c(0x203128),
                .surface1 = rgb24c(0x304a39),
                .surface_dim = rgb24c(0x111c18),
                .overlay0 = rgb24c(0x52675a),
                .overlay1 = rgb24c(0x7f9785),
                .text = rgb24c(0xd5ddcc),
                .subtext0 = rgb24c(0x9daa9b),
                .mauve = rgb24c(0xc3cea0),
                .green = rgb24c(0x91b99a),
                .yellow = rgb24c(0xd4b477),
                .red = rgb24c(0xe58c85),
                .blue = rgb24c(0x8faf9f),
                .teal = rgb24c(0x91b7b0),
                .peach = rgb24c(0xa8c98c),
            },
            .vesper => .{
                // .accent = rgb(168, 201, 140),
                .accent = rgb(255, 199, 153),
                .panel_bg = rgb(26, 26, 26),
                .surface0 = rgb(35, 35, 35),
                .surface1 = rgb(40, 40, 40),
                .surface_dim = rgb(16, 16, 16),
                .overlay0 = rgb(92, 92, 92),
                .overlay1 = rgb(126, 126, 126),
                .text = rgb(255, 255, 255),
                .subtext0 = rgb(160, 160, 160),
                .mauve = rgb(255, 209, 168),
                .green = rgb(153, 255, 228),
                .yellow = rgb(255, 199, 153),
                .red = rgb(255, 128, 128),
                .blue = rgb(176, 176, 176),
                .teal = rgb(102, 221, 204),
                .peach = rgb(255, 199, 153),
            },
            .catppuccin => .{
                .accent = rgb(137, 180, 250),
                .panel_bg = rgb(24, 24, 37),
                .surface0 = rgb(49, 50, 68),
                .surface1 = rgb(69, 71, 90),
                .surface_dim = rgb(30, 30, 46),
                .overlay0 = rgb(108, 112, 134),
                .overlay1 = rgb(127, 132, 156),
                .text = rgb(205, 214, 244),
                .subtext0 = rgb(166, 173, 200),
                .mauve = rgb(203, 166, 247),
                .green = rgb(166, 227, 161),
                .yellow = rgb(249, 226, 175),
                .red = rgb(243, 139, 168),
                .blue = rgb(137, 180, 250),
                .teal = rgb(148, 226, 213),
                .peach = rgb(250, 179, 135),
            },
            .tokyo_night => .{
                .accent = rgb(122, 162, 247),
                .panel_bg = rgb(26, 27, 38),
                .surface0 = rgb(36, 40, 59),
                .surface1 = rgb(65, 72, 104),
                .surface_dim = rgb(26, 27, 38),
                .overlay0 = rgb(86, 95, 137),
                .overlay1 = rgb(105, 113, 150),
                .text = rgb(192, 202, 245),
                .subtext0 = rgb(169, 177, 214),
                .mauve = rgb(187, 154, 247),
                .green = rgb(158, 206, 106),
                .yellow = rgb(224, 175, 104),
                .red = rgb(247, 118, 142),
                .blue = rgb(122, 162, 247),
                .teal = rgb(125, 207, 255),
                .peach = rgb(255, 158, 100),
            },
            .terminal => .{
                .accent = indexed(4),
                .panel_bg = .default,
                .surface0 = indexed(0),
                .surface1 = indexed(8),
                .surface_dim = indexed(8),
                .overlay0 = indexed(8),
                .overlay1 = indexed(7),
                .text = .default,
                .subtext0 = indexed(7),
                .mauve = indexed(5),
                .green = indexed(2),
                .yellow = indexed(3),
                .red = indexed(9),
                .blue = indexed(4),
                .teal = indexed(6),
                .peach = indexed(3),
            },
        },
    };
}

fn terminal(name: Builtin) @import("TerminalTheme.zig") {
    // Palette sources are recorded in docs/configuration.md. These are ANSI
    // colors, not a positional conversion of the chrome's semantic roles.
    return switch (name) {
        .osaka_jade => .{
            .foreground = rgb24(0xd5ddcc),
            .background = rgb24(0x111c18),
            .cursor_color = rgb24(0xc5e6a0),
            .cursor_text_color = rgb24(0x111c18),
            .palette = ansi(.{
                0x17241e, 0xe58c85, 0x91b99a, 0xd4b477, 0x8fa9b3, 0xb3a1b5, 0x91b7b0, 0xbbc8b5,
                0x7f9785, 0xf0a29a, 0xa8c98c, 0xd0c398, 0xabc1c8, 0xc4b3c5, 0xadd0c5, 0xd5ddcc,
            }),
        },
        .vesper => .{
            .foreground = rgb24(0xffffff),
            .background = rgb24(0x101010),
            .cursor_color = rgb24(0xffc799),
            .palette = ansi(.{
                0x101010, 0xf5a191, 0x90b99f, 0xe6b99d, 0xaca1cf, 0xe29eca, 0xea83a5, 0xa0a0a0,
                0x7e7e7e, 0xff8080, 0x99ffe4, 0xffc799, 0xb9aeda, 0xecaad6, 0xf591b2, 0xffffff,
            }),
        },
        .catppuccin => .{
            .foreground = rgb24(0xcdd6f4),
            .background = rgb24(0x1e1e2e),
            .cursor_color = rgb24(0xf5e0dc),
            .cursor_text_color = rgb24(0x11111b),
            .palette = ansi(.{
                0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8,
                0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
            }),
        },
        .tokyo_night => .{
            .foreground = rgb24(0xc0caf5),
            .background = rgb24(0x1a1b26),
            .cursor_color = rgb24(0xc0caf5),
            .palette = ansi(.{
                0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
                0x414868, 0xff899d, 0x9fe044, 0xfaba4a, 0x8db0ff, 0xc7a9ff, 0xa4daff, 0xc0caf5,
            }),
        },
        .terminal => .{},
    };
}

fn ansi(values: [16]u24) [16][3]u8 {
    var result: [16][3]u8 = undefined;
    for (&result, values) |*color, hex| {
        color.* = rgb24(hex);
    }

    return result;
}

fn rgb24(value: u24) [3]u8 {
    return .{ @intCast(value >> 16), @intCast((value >> 8) & 0xff), @intCast(value & 0xff) };
}

fn rgb24c(value: u24) ColorType {
    return .{ .rgb = rgb24(value) };
}

fn rgb(red: u8, green: u8, blue: u8) ColorType {
    return .{ .rgb = .{ red, green, blue } };
}

fn indexed(index: u8) ColorType {
    return .{ .indexed = index };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "Osaka Jade is the default theme and its panel takes the terminal background" {
    try std.testing.expectEqual(Builtin.osaka_jade, default_theme.base);
    try std.testing.expectEqualDeep(rgb(168, 201, 140), default_theme.palette.accent);
    try std.testing.expectEqualDeep(ColorType.default, default_theme.palette.panel_bg);
    try std.testing.expectEqualDeep(rgb(212, 180, 119), default_theme.palette.yellow);
    try std.testing.expectEqual([3]u8{ 0x11, 0x1c, 0x18 }, default_theme.terminal.background);
    try std.testing.expectEqual(@as(?[3]u8, .{ 0xc5, 0xe6, 0xa0 }), default_theme.terminal.cursor_color);
    try std.testing.expectEqual(@as(?[3]u8, .{ 0x11, 0x1c, 0x18 }), default_theme.terminal.cursor_text_color);
    try std.testing.expectEqual([3]u8{ 0x17, 0x24, 0x1e }, default_theme.terminal.palette[0]);
    try std.testing.expectEqual([3]u8{ 0xd5, 0xdd, 0xcc }, default_theme.terminal.palette[15]);
}

test "Vesper stays available with its defining colors" {
    const vesper = builtin(.vesper);
    try std.testing.expectEqual(Builtin.vesper, vesper.base);
    try std.testing.expectEqualDeep(rgb(255, 199, 153), vesper.palette.accent);
    try std.testing.expectEqualDeep(rgb(26, 26, 26), vesper.palette.panel_bg);
}

test "built-in theme names accept stable aliases" {
    try std.testing.expectEqual(Builtin.osaka_jade, fromName("osaka-jade").?.base);
    try std.testing.expectEqual(Builtin.osaka_jade, fromName("osaka_jade").?.base);
    try std.testing.expectEqual(Builtin.osaka_jade, fromName("OsakaJade").?.base);
    try std.testing.expectEqual(Builtin.catppuccin, fromName("catppuccin-mocha").?.base);
    try std.testing.expectEqual(Builtin.tokyo_night, fromName("TokyoNight").?.base);
    try std.testing.expectEqual(Builtin.terminal, fromName("default").?.base);
    try std.testing.expect(fromName("unknown") == null);
}

test "bundled palettes keep their defining colors" {
    const catppuccin = builtin(.catppuccin).palette;
    try std.testing.expectEqualDeep(rgb(137, 180, 250), catppuccin.accent);
    try std.testing.expectEqualDeep(rgb(24, 24, 37), catppuccin.panel_bg);

    const tokyo_night = builtin(.tokyo_night).palette;
    try std.testing.expectEqualDeep(rgb(122, 162, 247), tokyo_night.accent);
    try std.testing.expectEqualDeep(rgb(26, 27, 38), tokyo_night.panel_bg);
}

test "overrides replace only the requested color roles" {
    const base = builtin(.vesper);
    const custom = base.withOverrides(.{ .panel_bg = .default, .accent = rgb(1, 2, 3) });
    try std.testing.expectEqualDeep(ColorType.default, custom.palette.panel_bg);
    try std.testing.expectEqualDeep(rgb(1, 2, 3), custom.palette.accent);
    try std.testing.expectEqualDeep(base.palette.text, custom.palette.text);
}
