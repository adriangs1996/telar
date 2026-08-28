//! Client-side color themes.
//!
//! Themes color Telar's chrome. Pane contents keep the colors produced by the
//! child terminal, and workbench gaps keep the host terminal background.

const std = @import("std");
const ui = @import("telar-core").ui;

pub const Builtin = enum {
    vesper,
    catppuccin,
    tokyo_night,
    terminal,

    pub fn canonicalName(value: Builtin) []const u8 {
        return switch (value) {
            .vesper => "vesper",
            .catppuccin => "catppuccin",
            .tokyo_night => "tokyo-night",
            .terminal => "terminal",
        };
    }
};

pub const Palette = struct {
    accent: ui.Color,
    panel_bg: ui.Color,
    surface0: ui.Color,
    surface1: ui.Color,
    surface_dim: ui.Color,
    overlay0: ui.Color,
    overlay1: ui.Color,
    text: ui.Color,
    subtext0: ui.Color,
    mauve: ui.Color,
    green: ui.Color,
    yellow: ui.Color,
    red: ui.Color,
    blue: ui.Color,
    teal: ui.Color,
    peach: ui.Color,
};

/// Optional color values map directly to future user configuration keys.
/// `.default` means that the host terminal supplies the color.
pub const Overrides = struct {
    accent: ?ui.Color = null,
    panel_bg: ?ui.Color = null,
    surface0: ?ui.Color = null,
    surface1: ?ui.Color = null,
    surface_dim: ?ui.Color = null,
    overlay0: ?ui.Color = null,
    overlay1: ?ui.Color = null,
    text: ?ui.Color = null,
    subtext0: ?ui.Color = null,
    mauve: ?ui.Color = null,
    green: ?ui.Color = null,
    yellow: ?ui.Color = null,
    red: ?ui.Color = null,
    blue: ?ui.Color = null,
    teal: ?ui.Color = null,
    peach: ?ui.Color = null,
};

pub const Theme = struct {
    base: Builtin,
    palette: Palette,

    pub fn withOverrides(value: Theme, overrides: Overrides) Theme {
        var result = value;
        inline for (std.meta.fields(Overrides)) |field| {
            if (@field(overrides, field.name)) |color|
                @field(result.palette, field.name) = color;
        }
        return result;
    }
};

pub const default_theme = builtin(.vesper);

pub fn fromName(name: []const u8) ?Theme {
    if (eql(name, "vesper")) return builtin(.vesper);
    if (eql(name, "catppuccin") or eql(name, "catppuccin-mocha") or eql(name, "mocha"))
        return builtin(.catppuccin);
    if (eql(name, "tokyo-night") or eql(name, "tokyonight") or eql(name, "tokyo_night"))
        return builtin(.tokyo_night);
    if (eql(name, "terminal") or eql(name, "default")) return builtin(.terminal);
    return null;
}

pub fn builtin(name: Builtin) Theme {
    return .{
        .base = name,
        .palette = switch (name) {
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

fn rgb(red: u8, green: u8, blue: u8) ui.Color {
    return .{ .rgb = .{ red, green, blue } };
}

fn indexed(index: u8) ui.Color {
    return .{ .indexed = index };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "Vesper is the default theme" {
    try std.testing.expectEqual(Builtin.vesper, default_theme.base);
    try std.testing.expectEqualDeep(rgb(255, 199, 153), default_theme.palette.accent);
    try std.testing.expectEqualDeep(rgb(26, 26, 26), default_theme.palette.panel_bg);
}

test "built-in theme names accept stable aliases" {
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
    try std.testing.expectEqualDeep(ui.Color.default, custom.palette.panel_bg);
    try std.testing.expectEqualDeep(rgb(1, 2, 3), custom.palette.accent);
    try std.testing.expectEqualDeep(base.palette.text, custom.palette.text);
}
