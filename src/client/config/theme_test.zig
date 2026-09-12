const std = @import("std");
const Generation = @import("Generation.zig");
const Diagnostic = @import("Diagnostic.zig");
const themes = @import("../appearance/theme_support.zig");

test "one theme name supplies chrome terminal palette and cursor defaults" {
    const names = [_][]const u8{ "vesper", "catppuccin", "tokyo-night", "terminal" };
    const backgrounds = [_][3]u8{ .{ 16, 16, 16 }, .{ 30, 30, 46 }, .{ 26, 27, 38 }, .{ 24, 24, 27 } };
    const red = [_][3]u8{ .{ 245, 161, 145 }, .{ 243, 139, 168 }, .{ 247, 118, 142 }, .{ 205, 49, 49 } };
    for (names, backgrounds, red) |name, background, ansi_red| {
        var buffer: [128]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "return {{ api_version = 2, theme = '{s}' }}", .{name});
        const generation = try load(source, null);
        defer generation.deinit();
        const snapshot = &generation.snapshot;
        try std.testing.expectEqual(themes.fromName(name).?.base, snapshot.theme.base);
        try std.testing.expectEqual(background, snapshot.theme.terminal.background);
        try std.testing.expectEqual(ansi_red, snapshot.theme.terminal.palette[1]);
        try std.testing.expectEqualDeep(@import("GuiConfig.zig"){}, snapshot.gui);
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
    try std.testing.expectEqualDeep(@import("telar-core").Color{ .rgb = .{ 1, 2, 3 } }, snapshot.theme.palette.accent);
    try std.testing.expect(snapshot.theme.palette.text == .default);
    try std.testing.expectEqual([3]u8{ 0xab, 0xcd, 0xef }, snapshot.theme.terminal.foreground);
    try std.testing.expectEqual([3]u8{ 0x44, 0x55, 0x66 }, snapshot.theme.terminal.background);
    try std.testing.expectEqual(@as(?[3]u8, .{ 0x11, 0x22, 0x33 }), snapshot.theme.terminal.cursor_color);
    try std.testing.expectEqual(themes.builtin(.catppuccin).terminal.palette, snapshot.theme.terminal.palette);
    try std.testing.expectEqual(@as(f32, 20), snapshot.gui.font.size);

    const night = try load(source, "night");
    defer night.deinit();
    try std.testing.expectEqualDeep(themes.builtin(.tokyo_night), night.snapshot.theme);
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
    try std.testing.expectEqualDeep(themes.builtin(.tokyo_night), snapshot.resolveTheme(.dark, null));
    try std.testing.expectEqualDeep(themes.builtin(.vesper), snapshot.resolveTheme(.unknown, null));
    inline for (.{ .unknown, .light, .dark }) |appearance| {
        try std.testing.expectEqualDeep(themes.builtin(.catppuccin), snapshot.resolveTheme(appearance, themes.builtin(.catppuccin)));
    }
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
        "theme = 'missing'",                               "theme = false",                           "theme = { base = false }",                                   "theme = { typo = 1 }",
        "theme = 'vesper', client = { theme = 'vesper' }", "theme = { terminal = false }",            "theme = { terminal = { foreground = 'default' } }",          "theme = { terminal = { background = '#ff_fff' } }",
        "theme = { terminal = { cursor_color = 7 } }",     "theme = { terminal = { palette = {} } }", "theme = { terminal = { palette = { extra = '#123456' } } }", "theme = { terminal = { cursor_text_color = 'default' } }",
        "theme = { colors = { wrong = '#123456' } }",      "theme = { colors = 3 }",                  "profiles = { unused = { theme = 'missing' } }",              "profiles = { unused = { theme = 'vesper', client = { theme = 'catppuccin' } } }",
        "gui = { theme = { background = '#123456' } }",
    };
    for (invalid) |fields| {
        var buffer: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "return {{ api_version = 2, {s} }}", .{fields});
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@theme.lua", .number = 1 }));
        try std.testing.expect(diagnostic.message().len > 0);
    }
}

fn load(source: []const u8, profile: ?[]const u8) !*Generation {
    var diagnostic: Diagnostic = .{};
    return Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@theme.lua", .number = 1, .profile = profile });
}
