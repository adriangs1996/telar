const std = @import("std");
const Generation = @import("Generation.zig");
const Diagnostic = @import("Diagnostic.zig");
const GuiConfig = @import("GuiConfig.zig");

test "GUI configuration owns font names and overlays profiles independently of chrome" {
    const source =
        \\return { api_version = 2,
        \\  theme = { terminal = { foreground = "#ABCDEF", background = "#102030",
        \\      cursor_color = "#112233", cursor_text_color = "#445566",
        \\      palette = { "#000000", "#110000", "#001100", "#111100", "#000011", "#110011", "#001111", "#111111",
        \\                  "#222222", "#330000", "#003300", "#333300", "#000033", "#330033", "#003333", "#333333" } } },
        \\  gui = {
        \\    font = { family = "Example Mono", size = 17.5, line_height = 1.2, letter_spacing = 0.5 },
        \\    cursor = { style = "bar", blink = false, blink_interval_ms = 350 },
        \\  },
        \\  profiles = { large = { gui = { font = { size = 24 } }, theme = { terminal = { background = "#ffffff" } } } },
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@gui.lua", .number = 1, .profile = "large" });
    const config = generation.snapshot.gui;
    const terminal = generation.snapshot.theme.terminal;
    generation.deinit();
    try std.testing.expectEqualStrings("Example Mono", config.font.family.name());
    try std.testing.expectEqual(@as(f32, 24), config.font.size);
    try std.testing.expectEqual(@as(f32, 1.2), config.font.line_height);
    try std.testing.expectEqual(@as(f32, 0.5), config.font.letter_spacing);
    try std.testing.expectEqual(@as(f32, 18), config.font.scaledSize(0.75));
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, terminal.background);
    try std.testing.expectEqual([3]u8{ 0xab, 0xcd, 0xef }, terminal.foreground);
    try std.testing.expectEqual([3]u8{ 0x33, 0, 0x33 }, terminal.palette[13]);
    try std.testing.expectEqual(.bar, config.cursor.style);
    try std.testing.expect(!config.cursor.blink);
    try std.testing.expectEqual(@as(u32, 350), config.cursor.blink_interval_ms);
    try std.testing.expectEqual(@as(?[3]u8, .{ 0x11, 0x22, 0x33 }), terminal.cursor_color);
    try std.testing.expectEqual(@as(?[3]u8, .{ 0x44, 0x55, 0x66 }), terminal.cursor_text_color);

    const base = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { theme = 'vesper' } }", .source_name = "@base.lua", .number = 1 });
    defer base.deinit();
    try std.testing.expectEqualDeep(GuiConfig{}, base.snapshot.gui);
}

test "GUI validation rejects malformed values including profiles that are not selected" {
    const invalid = [_][]const u8{
        "gui = false",                                             "gui = { fonts = {} }",                                  "gui = { font = 'Mono' }",
        "gui = { font = { size = 5 } }",                           "gui = { font = { size = 97 } }",                        "gui = { font = { size = '15' } }",
        "gui = { font = { size = 0/0 } }",                         "gui = { font = { line_height = 0.7 } }",                "gui = { font = { letter_spacing = 21 } }",
        "gui = { font = { family = string.rep('a',257) } }",       "gui = { font = { family = 'a\\0b' } }",                 "gui = { font = { family = string.char(255) } }",
        "gui = { font = { family = 15 } }",                        "gui = { theme = { background = 'default' } }",          "gui = { theme = { foreground = '#12_456' } }",
        "gui = { theme = { palette = {} } }",                      "gui = { theme = { palette = { extra = '#112233' } } }", "gui = { cursor = { style = 'triangle' } }",
        "gui = { cursor = { blink = 1 } }",                        "gui = { cursor = { blink_interval_ms = 0 } }",          "gui = { cursor = { blink_interval_ms = 200.5 } }",
        "gui = { cursor = { blink_interval_ms = 200.00000001 } }", "gui = { cursor = { color = '#12345g' } }",              "profiles = { unused = { gui = { font = { size = 0 } } } }",
    };
    for (invalid) |fields| {
        var source: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&source, "return {{ api_version = 2, {s} }}", .{fields});
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = text, .source_name = "@invalid.lua", .number = 1 }));
        try std.testing.expect(diagnostic.message().len > 0);
    }
}
