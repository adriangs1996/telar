//! A preset owns chrome roles and native terminal colors. TUI panes and gaps
//! retain their host's defaults; child truecolor remains application-owned.

const core = @import("telar-core");
const std = @import("std");

pub const Builtin = enum {
    shade,
    vesper,
    catppuccin,
    tokyo_night,
    pierre_dark,
    pierre_dark_soft,
    terminal,

    pub fn canonicalName(self: Builtin) []const u8 {
        return switch (self) {
            .shade => "shade",
            .vesper => "vesper",
            .catppuccin => "catppuccin",
            .tokyo_night => "tokyo-night",
            .pierre_dark => "pierre-dark",
            .pierre_dark_soft => "pierre-dark-soft",
            .terminal => "terminal",
        };
    }
};

pub const Palette = @import("Palette.zig");

pub const Overrides = @import("Overrides.zig");

pub const Theme = @import("Theme.zig");
const TerminalTheme = @import("TerminalTheme.zig");

pub const default_theme = builtin(.shade);

pub fn fromName(name: []const u8) ?Theme {
    if (eql(name, "shade") or eql(name, "osaka-jade") or eql(name, "osaka_jade") or eql(name, "osakajade")) {
        return builtin(.shade);
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
    if (eql(name, "pierre-dark")) {
        return builtin(.pierre_dark);
    }
    if (eql(name, "pierre-dark-soft")) {
        return builtin(.pierre_dark_soft);
    }
    if (eql(name, "terminal") or eql(name, "default")) {
        return builtin(.terminal);
    }
    return null;
}

pub fn builtin(name: Builtin) Theme {
    return .{
        .base = name,
        .terminal = terminal(name),
        .syntax_styles = syntax(name),
        .palette = switch (name) {
            .shade => builtin(.vesper).withOverrides(.{
                .accent = rgb24c(0xa8c98c),
                .panel_bg = .default,
                .surface0 = rgb24c(0x232323),
                .surface1 = rgb24c(0x343434),
                .mauve = rgb24c(0xc3cea0),
                .green = rgb24c(0x91b99a),
                .yellow = rgb24c(0xd4b477),
                .red = rgb24c(0xe58c85),
                .blue = rgb24c(0x8faf9f),
                .teal = rgb24c(0x91b7b0),
                .peach = rgb24c(0xa8c98c),
            }).palette,
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
            .pierre_dark => .{
                .accent = rgb24c(0x009fff),
                .panel_bg = rgb24c(0x101010),
                .surface0 = rgb24c(0x1d1d1d),
                .surface1 = rgb24c(0x262626),
                .surface_dim = rgb24c(0x0a0a0a),
                .overlay0 = rgb24c(0x636363),
                .overlay1 = rgb24c(0x737373),
                .text = rgb24c(0xe5e5e5),
                .subtext0 = rgb24c(0xa3a3a3),
                .mauve = rgb24c(0x7b43f8),
                .green = rgb24c(0x07c480),
                .yellow = rgb24c(0xffca00),
                .red = rgb24c(0xff2e3f),
                .blue = rgb24c(0x009fff),
                .teal = rgb24c(0x08c0ef),
                .peach = rgb24c(0xffa359),
            },
            .pierre_dark_soft => .{
                .accent = rgb24c(0x69b1ff),
                .panel_bg = rgb24c(0x101010),
                .surface0 = rgb24c(0x262626),
                .surface1 = rgb24c(0x2c2c2c),
                .surface_dim = rgb24c(0x171717),
                .overlay0 = rgb24c(0x525252),
                .overlay1 = rgb24c(0x636363),
                .text = rgb24c(0xd4d4d4),
                .subtext0 = rgb24c(0x8a8a8a),
                .mauve = rgb24c(0x9d6afb),
                .green = rgb24c(0x60d199),
                .yellow = rgb24c(0xffd452),
                .red = rgb24c(0xff6762),
                .blue = rgb24c(0x69b1ff),
                .teal = rgb24c(0x68cdf2),
                .peach = rgb24c(0xffba82),
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

fn syntax(name: Builtin) Theme.SyntaxStyles {
    var result: Theme.SyntaxStyles = .initFill(null);
    const roles = .{ .plain, .keyword, .string, .number, .comment, .constant, .builtin_constant, .builtin, .func, .type, .parameter, .property, .namespace, .operator, .punctuation };
    const colors: [roles.len]u24 = switch (name) {
        .shade => .{ 0xd1d1cf, 0xa0a0a0, 0x91b99a, 0xe6b99d, 0x304a39, 0xc3cea0, 0xe6b99d, 0xa8c98c, 0xa8c98c, 0xc3cea0, 0xadd0c5, 0xbbc8b5, 0xc4b3c5, 0xa0a0a0, 0xa0a0a0 },
        .pierre_dark => .{ 0xe5e5e5, 0xff678d, 0x5ecc71, 0x68cdf2, 0x737373, 0xffd452, 0x68cdf2, 0xffab16, 0x9d6afb, 0xd568ea, 0xffa359, 0xffd452, 0xffab16, 0x08c0ef, 0x636363 },
        .pierre_dark_soft => .{ 0xd4d4d4, 0xff91a8, 0x8cda94, 0x96d9f6, 0x636363, 0xffde80, 0x96d9f6, 0xffde80, 0xba8ffd, 0xe290f0, 0xffba82, 0xffde80, 0xffde80, 0x68cdf2, 0x737373 },
        else => return result,
    };
    inline for (roles, colors) |role, color| {
        result.set(role, .{ .color = rgb24c(color), .italic = name == .shade and role == .parameter });
    }

    return result;
}

fn terminal(name: Builtin) TerminalTheme {
    // Palette sources are recorded in docs/configuration.md. These are ANSI
    // colors, not a positional conversion of the chrome's semantic roles.
    return switch (name) {
        .shade, .vesper => .{
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
        .pierre_dark, .pierre_dark_soft => .{
            .foreground = rgb24(if (name == .pierre_dark) 0xe5e5e5 else 0xd4d4d4),
            .background = rgb24(if (name == .pierre_dark) 0x0a0a0a else 0x171717),
            .cursor_color = rgb24(if (name == .pierre_dark) 0x009fff else 0x69b1ff),
            .cursor_text_color = rgb24(if (name == .pierre_dark) 0x0a0a0a else 0x171717),
            .palette = ansi(.{
                0x171717, 0xff2e3f, 0x0dbe4e, 0xffca00, 0x009fff, 0xe130ac, 0x08c0ef, 0xbcbcbc,
                0x171717, 0xff2e3f, 0x86c427, 0xffca00, 0x009fff, 0xe130ac, 0x08c0ef, 0xbcbcbc,
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

fn rgb24c(value: u24) core.Color {
    return .rgb(rgb24(value));
}

fn rgb(red: u8, green: u8, blue: u8) core.Color {
    return .rgb(.{ red, green, blue });
}

fn indexed(index: u8) core.Color {
    return .indexed(index);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "Shade is the default theme and its panel takes the terminal background" {
    try std.testing.expectEqual(Builtin.shade, default_theme.base);
    try std.testing.expectEqualDeep(rgb(168, 201, 140), default_theme.palette.accent);
    try std.testing.expectEqualDeep(core.Color.default, default_theme.palette.panel_bg);
    try std.testing.expectEqualDeep(rgb(212, 180, 119), default_theme.palette.yellow);

    const vesper = builtin(.vesper);
    try std.testing.expectEqualDeep(vesper.terminal, default_theme.terminal);
    try std.testing.expectEqualDeep(vesper.palette.text, default_theme.palette.text);
    try std.testing.expectEqualDeep(vesper.palette.subtext0, default_theme.palette.subtext0);
    try std.testing.expectEqualDeep(vesper.palette.surface_dim, default_theme.palette.surface_dim);
    try std.testing.expectEqualDeep(vesper.palette.overlay0, default_theme.palette.overlay0);
    try std.testing.expectEqualDeep(vesper.palette.overlay1, default_theme.palette.overlay1);
    try std.testing.expectEqualDeep(rgb(35, 35, 35), default_theme.palette.surface0);
    try std.testing.expectEqualDeep(rgb(52, 52, 52), default_theme.palette.surface1);
}

test "Shade syntax reproduces Osaka Jade roles without changing ANSI or chrome" {
    const theme = builtin(.shade);
    try std.testing.expectEqualDeep(rgb24c(0xa0a0a0), theme.syntax(.keyword));
    try std.testing.expectEqualDeep(rgb24c(0xa8c98c), theme.syntax(.func));
    try std.testing.expectEqualDeep(theme.syntax(.func), theme.syntax(.builtin));
    try std.testing.expectEqualDeep(rgb24c(0xc3cea0), theme.syntax(.type));
    try std.testing.expectEqualDeep(rgb24c(0xe6b99d), theme.syntax(.number));
    try std.testing.expectEqualDeep(rgb24c(0xd1d1cf), theme.syntax(.plain));
    try std.testing.expectEqualDeep(rgb24c(0x304a39), theme.syntax(.comment));
    try std.testing.expectEqualDeep(rgb24c(0xadd0c5), theme.syntax(.parameter));
    try std.testing.expect(theme.syntaxStyle(.parameter).italic);
    try std.testing.expect(!theme.syntaxStyle(.keyword).italic);
    const recolored = theme.withOverrides(.{ .text = rgb24c(0xff0000), .mauve = rgb24c(0x00ff00) });
    try std.testing.expectEqualDeep(theme.syntax_styles, recolored.syntax_styles);
    const fallback = builtin(.catppuccin).withOverrides(.{ .mauve = rgb24c(0x123456) });
    try std.testing.expectEqualDeep(rgb24c(0x123456), fallback.syntax(.keyword));
}

test "Vesper stays available with its defining colors" {
    const vesper = builtin(.vesper);
    try std.testing.expectEqual(Builtin.vesper, vesper.base);
    try std.testing.expectEqualDeep(rgb(255, 199, 153), vesper.palette.accent);
    try std.testing.expectEqualDeep(rgb(26, 26, 26), vesper.palette.panel_bg);
}

test "built-in theme names accept stable aliases" {
    try std.testing.expectEqualStrings("shade", Builtin.shade.canonicalName());
    try std.testing.expectEqual(Builtin.shade, fromName("shade").?.base);
    try std.testing.expectEqual(Builtin.shade, fromName("Shade").?.base);
    try std.testing.expectEqual(Builtin.shade, fromName("osaka-jade").?.base);
    try std.testing.expectEqual(Builtin.shade, fromName("osaka_jade").?.base);
    try std.testing.expectEqual(Builtin.shade, fromName("OsakaJade").?.base);
    try std.testing.expectEqual(Builtin.catppuccin, fromName("catppuccin-mocha").?.base);
    try std.testing.expectEqual(Builtin.tokyo_night, fromName("TokyoNight").?.base);
    try std.testing.expectEqualStrings("pierre-dark", Builtin.pierre_dark.canonicalName());
    try std.testing.expectEqualStrings("pierre-dark-soft", Builtin.pierre_dark_soft.canonicalName());
    try std.testing.expectEqual(Builtin.pierre_dark, fromName("pierre-dark").?.base);
    try std.testing.expectEqual(Builtin.pierre_dark_soft, fromName("Pierre-Dark-Soft").?.base);
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

test "Pierre variants preserve Neovim chrome syntax and ANSI colors" {
    const dark = builtin(.pierre_dark);
    const soft = builtin(.pierre_dark_soft);
    try std.testing.expectEqualDeep(rgb24c(0x009fff), dark.palette.accent);
    try std.testing.expectEqualDeep(rgb24c(0x69b1ff), soft.palette.accent);
    try std.testing.expectEqualDeep(rgb24c(0x0a0a0a), dark.palette.surface_dim);
    try std.testing.expectEqualDeep(rgb24c(0x171717), soft.palette.surface_dim);
    try std.testing.expectEqualDeep(rgb24c(0xff678d), dark.syntax(.keyword));
    try std.testing.expectEqualDeep(rgb24c(0xff91a8), soft.syntax(.keyword));
    try std.testing.expectEqualDeep(rgb24c(0x9d6afb), dark.syntax(.func));
    try std.testing.expectEqualDeep(rgb24c(0xba8ffd), soft.syntax(.func));
    try std.testing.expectEqualDeep(rgb24c(0x68cdf2), dark.syntax(.builtin_constant));
    try std.testing.expectEqualDeep(rgb24c(0x96d9f6), soft.syntax(.builtin_constant));
    try std.testing.expectEqualDeep(rgb24(0x0a0a0a), dark.terminal.background);
    try std.testing.expectEqualDeep(rgb24(0x171717), soft.terminal.background);
    try std.testing.expectEqualDeep(rgb24(0x009fff), dark.terminal.cursor_color.?);
    try std.testing.expectEqualDeep(rgb24(0x69b1ff), soft.terminal.cursor_color.?);
    try std.testing.expectEqualDeep(dark.terminal.palette, soft.terminal.palette);
    try std.testing.expectEqualDeep(rgb24(0x0dbe4e), dark.terminal.palette[2]);
    try std.testing.expectEqualDeep(rgb24(0x86c427), dark.terminal.palette[10]);
}

test "overrides replace only the requested color roles" {
    const base = builtin(.vesper);
    const custom = base.withOverrides(.{ .panel_bg = .default, .accent = rgb(1, 2, 3) });
    try std.testing.expectEqualDeep(core.Color.default, custom.palette.panel_bg);
    try std.testing.expectEqualDeep(rgb(1, 2, 3), custom.palette.accent);
    try std.testing.expectEqualDeep(base.palette.text, custom.palette.text);
}
