const Key = @import("Key.zig");
const InputModes = @import("InputModes.zig");
const std = @import("std");
const encoding = @import("encoding.zig");

test "cursor keys follow the focused child's mode" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[D",
        try encoding.encodeKey(&buffer, .plain(.left), .{}),
    );
    try std.testing.expectEqualStrings(
        "\x1bOD",
        try encoding.encodeKey(&buffer, .plain(.left), .{ .cursor_keys = true }),
    );
    try std.testing.expectEqualStrings(
        "\x1b[1;5D",
        try encoding.encodeKey(&buffer, .{ .code = .left, .mods = .{ .ctrl = true } }, .{ .cursor_keys = true }),
    );
}

test "paste framing follows the focused child's mode" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try encoding.encodePaste(&buffer, "hello", .{}));
    try std.testing.expectEqualStrings(
        "\x1b[200~hello\x1b[201~",
        try encoding.encodePaste(&buffer, "hello", .{ .bracketed_paste = true }),
    );
}

test "page keys preserve modifiers" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[5~",
        try encoding.encodeKey(&buffer, .plain(.page_up), .{}),
    );
    try std.testing.expectEqualStrings(
        "\x1b[6;5~",
        try encoding.encodeKey(&buffer, .{ .code = .page_down, .mods = .{ .ctrl = true } }, .{}),
    );
}

test "Enter modifiers follow the child's keyboard protocol" {
    var buffer: [32]u8 = undefined;
    var expected_buffer: [32]u8 = undefined;
    for (0..8) |bits| {
        const mods: Key.Mods = @bitCast(@as(u3, @intCast(bits)));
        const pressed: Key = .{ .code = .enter, .mods = mods };
        const legacy = if (mods.alt) "\x1b\r" else "\r";
        try std.testing.expectEqualStrings(legacy, try encoding.encodeKey(&buffer, pressed, .{}));
        const xterm = if (bits == 0) "\r" else try std.fmt.bufPrint(
            &expected_buffer,
            "\x1b[27;{d};13~",
            .{bits + 1},
        );
        try std.testing.expectEqualStrings(
            xterm,
            try encoding.encodeKey(&buffer, pressed, .{ .modify_other_keys_2 = true }),
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
                    try encoding.encodeKey(&buffer, pressed, .{
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

    try std.testing.expectEqualStrings("\x13", try encoding.encodeKey(&buffer, repeat, .{}));
    try std.testing.expectEqualStrings("", try encoding.encodeKey(&buffer, release, .{}));

    release.code = .left;
    try std.testing.expectEqualStrings("", try encoding.encodeKey(&buffer, release, .{ .cursor_keys = true }));
}

test "report-all mode encodes plain key lifecycles" {
    var buffer: [32]u8 = undefined;
    const modes: InputModes = .{ .kitty_keyboard_flags = 10 };
    var key: Key = .{
        .code = .{ .char = .init("x") },
        .physical = .{ .value = 120 },
    };

    try std.testing.expectEqualStrings("\x1b[120u", try encoding.encodeKey(&buffer, key, modes));
    key.phase = .repeat;
    try std.testing.expectEqualStrings("\x1b[120;1:2u", try encoding.encodeKey(&buffer, key, modes));
    key.phase = .release;
    try std.testing.expectEqualStrings("\x1b[120;1:3u", try encoding.encodeKey(&buffer, key, modes));
}

test "modified Enter encoding reports insufficient output space" {
    const pressed: Key = .{ .code = .enter, .mods = .{ .shift = true } };
    var kitty_buffer: [6]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, encoding.encodeKey(&kitty_buffer, pressed, .{ .kitty_keyboard_flags = 1 }));
    var xterm_buffer: [9]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, encoding.encodeKey(&xterm_buffer, pressed, .{ .modify_other_keys_2 = true }));
}

test "legacy Ctrl characters follow kitty's C0 table and fall back to the text" {
    var buffer: [32]u8 = undefined;
    const ctrl: Key.Mods = .{ .ctrl = true };
    const cases = [_]struct { text: []const u8, expected: []const u8 }{
        .{ .text = "2", .expected = "\x00" },
        .{ .text = "3", .expected = "\x1b" },
        .{ .text = "4", .expected = "\x1c" },
        .{ .text = "5", .expected = "\x1d" },
        .{ .text = "6", .expected = "\x1e" },
        .{ .text = "7", .expected = "\x1f" },
        .{ .text = "8", .expected = "\x7f" },
        .{ .text = "/", .expected = "\x1f" },
        .{ .text = "~", .expected = "\x1e" },
        .{ .text = "c", .expected = "\x03" },
        .{ .text = "[", .expected = "\x1b" },
        .{ .text = "1", .expected = "1" },
        .{ .text = "9", .expected = "9" },
        .{ .text = ".", .expected = "." },
        .{ .text = "=", .expected = "=" },
        .{ .text = "ñ", .expected = "ñ" },
    };

    for (cases) |case| {
        const key: Key = .{ .code = .{ .char = .init(case.text) }, .mods = ctrl };
        try std.testing.expectEqualStrings(case.expected, try encoding.encodeKey(&buffer, key, .{}));
    }

    const alt_ctrl: Key = .{ .code = .{ .char = .init("1") }, .mods = .{ .ctrl = true, .alt = true } };
    try std.testing.expectEqualStrings("\x1b1", try encoding.encodeKey(&buffer, alt_ctrl, .{}));
}

test "no printable ASCII key with Ctrl is unencodable for a legacy child" {
    var buffer: [32]u8 = undefined;
    for (0x20..0x7f) |byte| {
        const text = [_]u8{@intCast(byte)};
        const key: Key = .{ .code = .{ .char = .init(&text) }, .mods = .{ .ctrl = true } };
        const encoded = try encoding.encodeKey(&buffer, key, .{});
        try std.testing.expectEqual(@as(usize, 1), encoded.len);
    }
}

test "the longest kitty key fits max_key_bytes" {
    var buffer: [encoding.max_key_bytes]u8 = undefined;
    const key: Key = .{
        .code = .{ .char = .init("a") },
        .mods = .{ .shift = true },
        .phase = .repeat,
        .kitty = .{
            .primary = std.math.maxInt(u32),
            .shifted = 0x10ffff,
            .base = std.math.maxInt(u32),
        },
    };
    const all_kitty_flags = std.math.maxInt(u5);

    const encoded = try encoding.encodeKey(&buffer, key, .{ .kitty_keyboard_flags = all_kitty_flags });

    try std.testing.expectEqualStrings("\x1b[4294967295:1114111:4294967295;2:2;1114111u", encoded);
}
