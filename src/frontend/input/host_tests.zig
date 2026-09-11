const std = @import("std");
const encodeKey = @import("telar-client").encodeKey;
const term = @import("../presentation/screen_support.zig");
const InputModes = @import("telar-core").InputModes;
const Key = @import("telar-client").Key;
const encodePaste = @import("telar-client").encodePaste;

test "line-feed shortcuts preserve LF when encoded for a legacy child" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\n", try encodeKey(&buffer, term.parse("\n").?.event.key, .{}));
    try std.testing.expectEqualStrings("\r", try encodeKey(&buffer, term.parse("\r").?.event.key, .{}));
}

test "Kitty child event types preserve a modified character lifecycle" {
    var buffer: [32]u8 = undefined;
    const modes: InputModes = .{ .kitty_keyboard_flags = 7 };
    const cases = [_]struct { host: []const u8, expected: []const u8 }{
        .{ .host = "\x1b[115::115;5:1u", .expected = "\x1b[115::115;5u" },
        .{ .host = "\x1b[115::115;5:2u", .expected = "\x1b[115::115;5:2u" },
        .{ .host = "\x1b[115::115;1:3u", .expected = "\x1b[115::115;1:3u" },
    };

    for (cases) |case| {
        const key = term.parse(case.host).?.event.key;
        try std.testing.expectEqualStrings(case.expected, try encodeKey(&buffer, key, modes));
    }
}

test "Kitty alternate codepoints are forwarded only when the child requests them" {
    var buffer: [32]u8 = undefined;
    const key = term.parse("\x1b[47:63:47;6:1u").?.event.key;

    try std.testing.expectEqualStrings(
        "\x1b[47:63:47;6u",
        try encodeKey(&buffer, key, .{ .kitty_keyboard_flags = 7 }),
    );
    try std.testing.expectEqualStrings(
        "\x1b[47;6u",
        try encodeKey(&buffer, key, .{ .kitty_keyboard_flags = 3 }),
    );
}

test "Kitty functional keys preserve repeat and release suffixes" {
    var buffer: [32]u8 = undefined;
    const modes: InputModes = .{ .kitty_keyboard_flags = 2 };

    const pressed_up = term.parse("\x1b[1;1:1A").?.event.key;
    try std.testing.expectEqualStrings("\x1b[A", try encodeKey(&buffer, pressed_up, .{
        .kitty_keyboard_flags = 2,
        .cursor_keys = true,
    }));

    const repeated_up = term.parse("\x1b[1;5:2A").?.event.key;
    try std.testing.expectEqualStrings("\x1b[1;5:2A", try encodeKey(&buffer, repeated_up, modes));
    try std.testing.expectEqualStrings("\x1b[1;5A", try encodeKey(&buffer, repeated_up, .{}));

    const released_delete = term.parse("\x1b[3;5:3~").?.event.key;
    try std.testing.expectEqualStrings("\x1b[3;5:3~", try encodeKey(&buffer, released_delete, modes));
    try std.testing.expectEqualStrings("", try encodeKey(&buffer, released_delete, .{}));
}

test "Kitty associated text follows the produced character rather than the physical key" {
    var buffer: [64]u8 = undefined;
    const cases = [_]struct { host: []const u8, expected: []const u8 }{
        .{ .host = "a", .expected = "\x1b[97;1;97u" },
        .{ .host = "A", .expected = "\x1b[65;1;65u" },
        .{ .host = " ", .expected = "\x1b[32;1;32u" },
        .{ .host = "ñ", .expected = "\x1b[241;1;241u" },
        .{ .host = "界", .expected = "\x1b[30028;1;30028u" },
        .{ .host = "😀", .expected = "\x1b[128512;1;128512u" },
        .{ .host = "\x1b[97:65:113;2u", .expected = "\x1b[97;2;65u" },
        .{ .host = "\x1b[47:63:47;2:2u", .expected = "\x1b[47;2:2;63u" },
        .{ .host = "\x1b[97;1:2u", .expected = "\x1b[97;1:2;97u" },
        .{ .host = "\x1b[97;1:3u", .expected = "\x1b[97;1:3u" },
    };

    for (cases) |case| {
        const key = term.parse(case.host).?.event.key;
        try std.testing.expectEqualStrings(case.expected, try encodeKey(&buffer, key, .{ .kitty_keyboard_flags = 27 }));
    }

    const shifted = term.parse("\x1b[97:65:113;2u").?.event.key;
    try std.testing.expectEqualStrings("\x1b[97:65:113;2;65u", try encodeKey(&buffer, shifted, .{ .kitty_keyboard_flags = 31 }));
    try std.testing.expectEqualStrings("\x1b[97;2;65u", try encodeKey(&buffer, shifted, .{ .kitty_keyboard_flags = 19 }));
    try std.testing.expectEqualStrings("A", try encodeKey(&buffer, shifted, .{}));
}

test "Kitty associated text never turns shortcuts controls or releases into text" {
    var buffer: [64]u8 = undefined;
    var baseline_buffer: [64]u8 = undefined;
    const non_text = [_][]const u8{
        "\x03",        "\x1ba",        "\r",              "\t",       "\x7f",      "\x1b",
        "\x1b[A",      "\x1b[3~",      "\x1b[0u",         "\x1b[31u", "\x1b[128u", "\x1b[159u",
        "\x1b[57441u", "\x1b[97;1:3u", "\x1b[97:65;2:3u",
    };

    for (1..16) |bits| {
        const flags: u5 = @intCast(bits);

        for (non_text) |host| {
            const key = term.parse(host).?.event.key;
            const baseline = try encodeKey(&baseline_buffer, key, .{ .kitty_keyboard_flags = flags });
            try std.testing.expectEqualStrings(baseline, try encodeKey(&buffer, key, .{ .kitty_keyboard_flags = flags | 16 }));
        }

        for (0..8) |mods_bits| {
            const mods: Key.Mods = @bitCast(@as(u3, @intCast(mods_bits)));
            if (!mods.ctrl and !mods.alt) {
                continue;
            }

            for ([_]Key.Phase{ .press, .repeat, .release }) |phase| {
                const key: Key = .{ .code = .{ .char = .init("c") }, .mods = mods, .phase = phase };
                const baseline = try encodeKey(&baseline_buffer, key, .{ .kitty_keyboard_flags = flags });
                try std.testing.expectEqualStrings(baseline, try encodeKey(&buffer, key, .{ .kitty_keyboard_flags = flags | 16 }));
            }
        }
    }
}

test "associated text preserves legacy text and paste and requires its own flag" {
    var buffer: [64]u8 = undefined;
    const key = term.parse("a").?.event.key;

    for (0..32) |bits| {
        const flags: u5 = @intCast(bits);
        const expected = if (flags & 8 == 0) "a" else if (flags & 16 == 0) "\x1b[97u" else "\x1b[97;1;97u";
        try std.testing.expectEqualStrings(expected, try encodeKey(&buffer, key, .{ .kitty_keyboard_flags = flags }));
        try std.testing.expectEqualStrings("a", try encodePaste(&buffer, "a", .{ .kitty_keyboard_flags = flags }));
        try std.testing.expectEqualStrings("\x1b[200~a\x1b[201~", try encodePaste(&buffer, "a", .{
            .kitty_keyboard_flags = flags,
            .bracketed_paste = true,
        }));
    }
}

test "associated text respects the output buffer bound" {
    const key = term.parse("a").?.event.key;
    var buffer: [10]u8 = undefined;

    for (0..buffer.len) |len| {
        try std.testing.expectError(error.WriteFailed, encodeKey(buffer[0..len], key, .{ .kitty_keyboard_flags = 27 }));
    }

    try std.testing.expectEqualStrings("\x1b[97;1;97u", try encodeKey(&buffer, key, .{ .kitty_keyboard_flags = 27 }));
}
