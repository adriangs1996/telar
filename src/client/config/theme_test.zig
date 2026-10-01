const cellgrid = @import("cellgrid");
const data = @import("model");
const std = @import("std");
const Generation = @import("Generation.zig");
const GuiConfig = @import("GuiConfig.zig");

test "one theme name supplies chrome terminal palette and cursor defaults" {
    const names = [_][]const u8{ "shade", "vesper", "catppuccin", "tokyo-night", "pierre-dark", "pierre-dark-soft", "kanagawa", "kanagawa-dragon", "terminal" };
    const backgrounds = [_][3]u8{ .{ 16, 16, 16 }, .{ 16, 16, 16 }, .{ 30, 30, 46 }, .{ 26, 27, 38 }, .{ 10, 10, 10 }, .{ 23, 23, 23 }, .{ 31, 31, 40 }, .{ 24, 22, 22 }, .{ 24, 24, 27 } };
    const red = [_][3]u8{ .{ 245, 161, 145 }, .{ 245, 161, 145 }, .{ 243, 139, 168 }, .{ 247, 118, 142 }, .{ 255, 46, 63 }, .{ 255, 46, 63 }, .{ 195, 64, 67 }, .{ 196, 116, 110 }, .{ 205, 49, 49 } };
    for (names, backgrounds, red) |name, background, ansi_red| {
        var buffer: [128]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "return {{ api_version = 2, theme = '{s}' }}", .{name});
        const generation = try load(source, null);
        defer generation.deinit();
        const snapshot = &generation.snapshot;
        try std.testing.expectEqual(data.theme_support.fromName(name).?.base, snapshot.theme.base);
        try std.testing.expectEqual(background, snapshot.theme.terminal.background);
        try std.testing.expectEqual(ansi_red, snapshot.theme.terminal.palette[1]);
        try std.testing.expectEqualDeep(GuiConfig{}, snapshot.gui);
    }
}

test "theme overrides inherit through profiles and selecting a preset replaces the complete theme" {
    const source =
        \\return { api_version = 2,
        \\  theme = { base = "catppuccin", colors = { accent = "#010203", text = "default" },
        \\    terminal = { foreground = "#abcdef", cursor_color = "#112233" } },
        \\  gui = { font = { size = 17 } },
        \\  profiles = {
        \\    custom = { theme = { terminal = { background = "#445566" } }, gui = { font = { size = 20 } } },
        \\    night = { theme = "tokyo-night" },
        \\  }
        \\}
    ;
    const custom = try load(source, "custom");
    defer custom.deinit();
    const snapshot = &custom.snapshot;
    try std.testing.expectEqualDeep(cellgrid.Color.rgb(.{ 1, 2, 3 }), snapshot.theme.palette.accent);
    try std.testing.expect(snapshot.theme.palette.text.kind == .default);
    try std.testing.expectEqual([3]u8{ 0xab, 0xcd, 0xef }, snapshot.theme.terminal.foreground);
    try std.testing.expectEqual([3]u8{ 0x44, 0x55, 0x66 }, snapshot.theme.terminal.background);
    try std.testing.expectEqual(@as(?[3]u8, .{ 0x11, 0x22, 0x33 }), snapshot.theme.terminal.cursor_color);
    try std.testing.expectEqual(data.theme_support.builtin(.catppuccin).terminal.palette, snapshot.theme.terminal.palette);
    try std.testing.expectEqual(@as(f32, 20), snapshot.gui.font.size);

    const night = try load(source, "night");
    defer night.deinit();
    try std.testing.expectEqualDeep(data.theme_support.builtin(.tokyo_night), night.snapshot.theme);
    try std.testing.expectEqual(@as(f32, 17), night.snapshot.gui.font.size);
}

test "CLI theme locking and appearance variants resolve both color groups together" {
    const generation = try load(
        \\return { api_version = 2, theme = "vesper",
        \\  client = { appearance = {
        \\    light = { terminal = { background = "#ffffff" } },
        \\    dark = "tokyo-night"
        \\  } }
        \\}
    , null);
    defer generation.deinit();
    const snapshot = &generation.snapshot;
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, snapshot.resolveTheme(.light, null).terminal.background);
    try std.testing.expectEqualDeep(data.theme_support.builtin(.tokyo_night), snapshot.resolveTheme(.dark, null));
    try std.testing.expectEqualDeep(data.theme_support.builtin(.vesper), snapshot.resolveTheme(.unknown, null));
    inline for (.{ .unknown, .light, .dark }) |appearance| {
        try std.testing.expectEqualDeep(data.theme_support.builtin(.catppuccin), snapshot.resolveTheme(appearance, data.theme_support.builtin(.catppuccin)));
    }
}

test "the default generation selects Shade and the Lua spellings agree" {
    const implicit = try load("return { api_version = 2 }", null);
    defer implicit.deinit();
    try std.testing.expectEqualDeep(data.theme_support.default_theme, implicit.snapshot.theme);
    try std.testing.expect(implicit.snapshot.theme.palette.panel_bg.kind == .default);
    for ([_][]const u8{ "shade", "osaka-jade", "osaka_jade", "osakajade" }) |name| {
        var buffer: [128]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "return {{ api_version = 2, theme = '{s}' }}", .{name});
        const generation = try load(source, null);
        defer generation.deinit();
        try std.testing.expectEqualDeep(data.theme_support.builtin(.shade), generation.snapshot.theme);
    }
}

test "syntax styles inherit through profiles independently of chrome and terminal colors" {
    const source =
        \\return { api_version = 2,
        \\  theme = { base = "shade", syntax = {
        \\    keyword = "#112233", parameter = { fg = "#445566", italic = true },
        \\    comment = { bold = true }
        \\  } },
        \\  profiles = {
        \\    custom = { theme = { syntax = { parameter = { italic = false } } } },
        \\    reset = { theme = "catppuccin" }
        \\  }
        \\}
    ;
    const generation = try load(source, "custom");
    defer generation.deinit();
    const theme = generation.snapshot.theme;
    try std.testing.expectEqualDeep(cellgrid.Color.rgb(.{ 0x11, 0x22, 0x33 }), theme.syntax(.keyword));
    try std.testing.expectEqualDeep(cellgrid.Color.rgb(.{ 0x44, 0x55, 0x66 }), theme.syntax(.parameter));
    try std.testing.expect(!theme.syntaxStyle(.parameter).italic);
    try std.testing.expect(theme.syntaxStyle(.comment).bold);
    try std.testing.expectEqualDeep(data.theme_support.builtin(.shade).syntax(.comment), theme.syntax(.comment));
    try std.testing.expectEqualDeep(data.theme_support.builtin(.shade).palette, theme.palette);
    try std.testing.expectEqualDeep(data.theme_support.builtin(.shade).terminal, theme.terminal);
    const reset = try load(source, "reset");
    defer reset.deinit();
    try std.testing.expectEqualDeep(data.theme_support.builtin(.catppuccin), reset.snapshot.theme);
}

test "legacy client theme spelling selects the same complete preset" {
    const old = try load("return { api_version = 2, client = { theme = 'catppuccin' } }", null);
    defer old.deinit();
    const current = try load("return { api_version = 2, theme = 'catppuccin' }", null);
    defer current.deinit();
    try std.testing.expectEqualDeep(current.snapshot.theme, old.snapshot.theme);
}

test "invalid or ambiguous themes reject the whole generation including unused profiles" {
    const invalid = [_][]const u8{
        "theme = 'missing'",                                       "theme = false",                                     "theme = { base = false }",                                      "theme = { typo = 1 }",
        "theme = 'vesper', client = { theme = 'vesper' }",         "theme = { terminal = false }",                      "theme = { terminal = { foreground = 'default' } }",             "theme = { terminal = { background = '#ff_fff' } }",
        "theme = { terminal = { cursor_color = 7 } }",             "theme = { terminal = { palette = {} } }",           "theme = { terminal = { palette = { extra = '#123456' } } }",    "theme = { terminal = { cursor_text_color = 'default' } }",
        "theme = { colors = { wrong = '#123456' } }",              "theme = { colors = 3 }",                            "profiles = { unused = { theme = 'missing' } }",                 "profiles = { unused = { theme = 'vesper', client = { theme = 'catppuccin' } } }",
        "gui = { theme = { background = '#123456' } }",            "theme = { syntax = false }",                        "theme = { syntax = { unknown = '#123456' } }",                  "theme = { syntax = { keyword = '#invalid' } }",
        "theme = { syntax = { parameter = { italic = 'yes' } } }", "theme = { syntax = { parameter = { bold = 1 } } }", "theme = { syntax = { keyword = { background = '#123456' } } }",
    };
    for (invalid) |fields| {
        var buffer: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "return {{ api_version = 2, {s} }}", .{fields});
        var diagnostic: data.Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@theme.lua", .number = 1 }));
        try std.testing.expect(diagnostic.message().len > 0);
    }
}

fn load(source: []const u8, profile: ?[]const u8) !*Generation {
    var diagnostic: data.Diagnostic = .{};
    return Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@theme.lua", .number = 1, .profile = profile });
}
