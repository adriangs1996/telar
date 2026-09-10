const std = @import("std");
const input = @import("root.zig");
const Key = input.Key;
const Modes = input.Modes;
const encodeKey = input.encodeKey;
const encodePaste = input.encodePaste;

test "cursor keys follow the focused child's mode" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[D",
        try encodeKey(&buffer, .plain(.left), .{}),
    );
    try std.testing.expectEqualStrings(
        "\x1bOD",
        try encodeKey(&buffer, .plain(.left), .{ .cursor_keys = true }),
    );
    try std.testing.expectEqualStrings(
        "\x1b[1;5D",
        try encodeKey(&buffer, .{ .code = .left, .mods = .{ .ctrl = true } }, .{ .cursor_keys = true }),
    );
}

test "paste framing follows the focused child's mode" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try encodePaste(&buffer, "hello", .{}));
    try std.testing.expectEqualStrings(
        "\x1b[200~hello\x1b[201~",
        try encodePaste(&buffer, "hello", .{ .bracketed_paste = true }),
    );
}

test "page keys preserve modifiers" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[5~",
        try encodeKey(&buffer, .plain(.page_up), .{}),
    );
    try std.testing.expectEqualStrings(
        "\x1b[6;5~",
        try encodeKey(&buffer, .{ .code = .page_down, .mods = .{ .ctrl = true } }, .{}),
    );
}

test "Enter modifiers follow the child's keyboard protocol" {
    var buffer: [32]u8 = undefined;
    var expected_buffer: [32]u8 = undefined;
    for (0..8) |bits| {
        const mods: Key.Mods = @bitCast(@as(u3, @intCast(bits)));
        const pressed: Key = .{ .code = .enter, .mods = mods };
        const legacy = if (mods.alt) "\x1b\r" else "\r";
        try std.testing.expectEqualStrings(legacy, try encodeKey(&buffer, pressed, .{}));
        const xterm = if (bits == 0) "\r" else try std.fmt.bufPrint(
            &expected_buffer,
            "\x1b[27;{d};13~",
            .{bits + 1},
        );
        try std.testing.expectEqualStrings(
            xterm,
            try encodeKey(&buffer, pressed, .{ .modify_other_keys_2 = true }),
        );
        for ([_]u5{ 1, 5, 8, 31 }) |flags| {
            const kitty = if (bits != 0 or flags & 8 != 0) encoded: {
                if (bits != 0) {
                    break :encoded try std.fmt.bufPrint(&expected_buffer, "\x1b[13;{d}u", .{bits + 1});
                }

                break :encoded "\x1b[13u";
            } else "\r";
            for ([_]bool{ false, true }) |modify_other_keys| {
                try std.testing.expectEqualStrings(
                    kitty,
                    try encodeKey(&buffer, pressed, .{
                        .kitty_keyboard_flags = flags,
                        .modify_other_keys_2 = modify_other_keys,
                    }),
                );
            }
        }
    }
}

test "legacy children receive repeats as presses and never receive releases" {
    var buffer: [32]u8 = undefined;
    const repeat: Key = .{
        .code = .{ .char = .init("s") },
        .mods = .{ .ctrl = true },
        .phase = .repeat,
        .physical = .{ .value = 115 },
    };
    var release = repeat;
    release.phase = .release;

    try std.testing.expectEqualStrings("\x13", try encodeKey(&buffer, repeat, .{}));
    try std.testing.expectEqualStrings("", try encodeKey(&buffer, release, .{}));

    release.code = .left;
    try std.testing.expectEqualStrings("", try encodeKey(&buffer, release, .{ .cursor_keys = true }));
}

test "report-all mode encodes plain key lifecycles" {
    var buffer: [32]u8 = undefined;
    const modes: Modes = .{ .kitty_keyboard_flags = 10 };
    var key: Key = .{
        .code = .{ .char = .init("x") },
        .physical = .{ .value = 120 },
    };

    try std.testing.expectEqualStrings("\x1b[120u", try encodeKey(&buffer, key, modes));
    key.phase = .repeat;
    try std.testing.expectEqualStrings("\x1b[120;1:2u", try encodeKey(&buffer, key, modes));
    key.phase = .release;
    try std.testing.expectEqualStrings("\x1b[120;1:3u", try encodeKey(&buffer, key, modes));
}

test "modified Enter encoding reports insufficient output space" {
    const pressed: Key = .{ .code = .enter, .mods = .{ .shift = true } };
    var kitty_buffer: [6]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, encodeKey(&kitty_buffer, pressed, .{ .kitty_keyboard_flags = 1 }));
    var xterm_buffer: [9]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, encodeKey(&xterm_buffer, pressed, .{ .modify_other_keys_2 = true }));
}
