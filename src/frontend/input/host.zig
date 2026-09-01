//! Semantic child-input encoding.
//!
//! Host-terminal bytes never cross this boundary. Keys are parsed first and
//! encoded against modes reported by the runtime-owned VT.

const std = @import("std");
const core = @import("telar-core");
const term = @import("../presentation/root.zig").screen;

pub const Key = term.Event.Key;
pub const Modes = core.schema.frame.InputModes;

pub fn encodeKey(buffer: []u8, key: Key, modes: Modes) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    const encoding: Encoding = .init(key, modes);

    if (key.phase == .release and encoding.event == null) {
        return writer.buffered();
    }

    if (try encodeText(&writer, key, encoding)) {
        return writer.buffered();
    }

    if (encoding.usesKittyFor(key)) {
        try encodeKitty(&writer, key, encoding);

        return writer.buffered();
    }
    if (key.phase == .release) {
        switch (key.code) {
            .enter, .backspace, .tab, .back_tab => return writer.buffered(),
            else => {},
        }
    }

    switch (key.code) {
        .char => |char| try encodeLegacyCharacter(&writer, char, key),
        .up => try encodeCursor(&writer, 'A', encoding),
        .down => try encodeCursor(&writer, 'B', encoding),
        .right => try encodeCursor(&writer, 'C', encoding),
        .left => try encodeCursor(&writer, 'D', encoding),
        .home => try encodeCursor(&writer, 'H', encoding),
        .end => try encodeCursor(&writer, 'F', encoding),
        .delete => try encodeNumbered(&writer, 3, encoding),
        .page_up => try encodeNumbered(&writer, 5, encoding),
        .page_down => try encodeNumbered(&writer, 6, encoding),
        .enter => {
            if (modes.modify_other_keys_2 and encoding.modifier != 1) {
                try writer.print("\x1b[27;{d};13~", .{encoding.modifier});
            } else {
                try withAlt(&writer, key.mods.alt, "\r");
            }
        },
        .escape => try withAlt(&writer, key.mods.alt, "\x1b"),
        .backspace => try withAlt(&writer, key.mods.alt, if (key.mods.ctrl) "\x08" else "\x7f"),
        .tab => if (key.mods.shift)
            try withAlt(&writer, key.mods.alt, "\x1b[Z")
        else
            try withAlt(&writer, key.mods.alt, "\t"),
        .back_tab => try withAlt(&writer, key.mods.alt, "\x1b[Z"),
    }
    return writer.buffered();
}

const Encoding = struct {
    modifier: u8,
    kitty_flags: u5,
    event_types: bool,
    event: ?u2,
    cursor_keys: bool,

    fn init(key: Key, modes: Modes) Encoding {
        const event_types = modes.kitty_keyboard_flags & 0b00010 != 0;

        return .{
            .modifier = 1 + @as(u8, @intFromBool(key.mods.shift)) +
                2 * @as(u8, @intFromBool(key.mods.alt)) +
                4 * @as(u8, @intFromBool(key.mods.ctrl)),
            .kitty_flags = modes.kitty_keyboard_flags,
            .event_types = event_types,
            .event = if (event_types and key.phase != .press) @intFromEnum(key.phase) else null,
            .cursor_keys = modes.cursor_keys,
        };
    }

    fn reportsAllKeys(encoding: Encoding) bool {
        return encoding.kitty_flags & 0b01000 != 0;
    }

    fn usesKittyFor(encoding: Encoding, key: Key) bool {
        if (encoding.kitty_flags == 0) {
            return false;
        }

        return switch (key.code) {
            .char, .escape => true,
            .enter, .backspace, .tab => encoding.modifier != 1 or
                encoding.reportsAllKeys() or
                (encoding.event_types and key.kitty != null),
            else => false,
        };
    }
};

fn encodeText(writer: *std.Io.Writer, key: Key, encoding: Encoding) !bool {
    if (encoding.reportsAllKeys()) {
        return false;
    }

    const char = switch (key.code) {
        .char => |value| value,
        else => return false,
    };
    if (encoding.event_types and key.kitty != null) {
        return false;
    }
    if (key.mods.ctrl or key.mods.alt) {
        return false;
    }
    if (key.phase == .release) {
        return true;
    }

    if (key.mods.shift) {
        if (key.kitty) |codepoints| {
            if (codepoints.shifted) |shifted| {
                var bytes: [4]u8 = undefined;
                const scalar = std.math.cast(u21, shifted) orelse return error.UnencodableKey;
                const len = std.unicode.utf8Encode(scalar, &bytes) catch return error.UnencodableKey;
                try writer.writeAll(bytes[0..len]);

                return true;
            }
        }
    }

    try writer.writeAll(char.slice());

    return true;
}

fn encodeKitty(writer: *std.Io.Writer, key: Key, encoding: Encoding) !void {
    try writer.writeAll("\x1b[");
    try encodeKittyCodepoints(writer, key, encoding.kitty_flags);
    if (encoding.modifier != 1 or encoding.event != null) {
        try writer.print(";{d}", .{encoding.modifier});
    }
    if (encoding.event) |event| {
        try writer.print(":{d}", .{event});
    }
    try writer.writeByte('u');
}

fn encodeKittyCodepoints(writer: *std.Io.Writer, key: Key, flags: u5) !void {
    if (key.kitty) |codepoints| {
        try writer.print("{d}", .{codepoints.primary});
        if (flags & 0b00100 != 0 and (codepoints.shifted != null or codepoints.base != null)) {
            try writer.writeByte(':');
            if (codepoints.shifted) |shifted| {
                try writer.print("{d}", .{shifted});
            }
            if (codepoints.base) |base| {
                try writer.print(":{d}", .{base});
            }
        }

        return;
    }

    const codepoint: u32 = switch (key.code) {
        .char => |char| std.unicode.utf8Decode(char.slice()) catch return error.UnencodableKey,
        .enter => 13,
        .escape => 27,
        .backspace => 127,
        .tab => 9,
        else => return error.UnencodableKey,
    };
    try writer.print("{d}", .{codepoint});
}

fn encodeLegacyCharacter(writer: *std.Io.Writer, char: term.Event.Char, key: Key) !void {
    if (key.mods.alt) {
        try writer.writeByte(0x1b);
    }
    if (!key.mods.ctrl) {
        try writer.writeAll(char.slice());

        return;
    }
    if (char.len != 1) {
        return error.UnencodableControlKey;
    }

    const byte = char.bytes[0];
    const encoded: u8 = if (std.ascii.isAlphabetic(byte))
        std.ascii.toUpper(byte) & 0x1f
    else switch (byte) {
        ' ', '@' => @as(u8, 0),
        '[' => 0x1b,
        '\\' => 0x1c,
        ']' => 0x1d,
        '^' => 0x1e,
        '_' => 0x1f,
        '?' => 0x7f,
        else => return error.UnencodableControlKey,
    };
    try writer.writeByte(encoded);
}

pub fn encodePaste(buffer: []u8, text: []const u8, modes: Modes) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    if (modes.bracketed_paste) try writer.writeAll("\x1b[200~");
    try writer.writeAll(text);
    if (modes.bracketed_paste) try writer.writeAll("\x1b[201~");
    return writer.buffered();
}

fn encodeCursor(writer: *std.Io.Writer, final: u8, encoding: Encoding) !void {
    if (encoding.event) |event| {
        try writer.print("\x1b[1;{d}:{d}{c}", .{ encoding.modifier, event, final });
    } else if (encoding.modifier != 1) {
        try writer.print("\x1b[1;{d}{c}", .{ encoding.modifier, final });
    } else if (encoding.event_types) {
        try writer.writeAll("\x1b[");
        try writer.writeByte(final);
    } else if (encoding.cursor_keys) {
        try writer.writeAll("\x1bO");
        try writer.writeByte(final);
    } else {
        try writer.writeAll("\x1b[");
        try writer.writeByte(final);
    }
}

fn encodeNumbered(writer: *std.Io.Writer, number: u8, encoding: Encoding) !void {
    if (encoding.event) |event| {
        try writer.print("\x1b[{d};{d}:{d}~", .{ number, encoding.modifier, event });
    } else if (encoding.modifier != 1) {
        try writer.print("\x1b[{d};{d}~", .{ number, encoding.modifier });
    } else {
        try writer.print("\x1b[{d}~", .{number});
    }
}

fn withAlt(writer: *std.Io.Writer, alt: bool, bytes: []const u8) !void {
    if (alt) try writer.writeByte(0x1b);
    try writer.writeAll(bytes);
}

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

test "line-feed shortcuts preserve LF when encoded for a legacy child" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\n", try encodeKey(&buffer, term.parse("\n").?.event.key, .{}));
    try std.testing.expectEqualStrings("\r", try encodeKey(&buffer, term.parse("\r").?.event.key, .{}));
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

test "Kitty child event types preserve a modified character lifecycle" {
    var buffer: [32]u8 = undefined;
    const modes: Modes = .{ .kitty_keyboard_flags = 7 };
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
    const modes: Modes = .{ .kitty_keyboard_flags = 2 };

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
