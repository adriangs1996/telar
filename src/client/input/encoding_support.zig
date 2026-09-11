//! Semantic child-input encoding.
//!
//! Host-terminal bytes never cross this boundary. Keys are parsed first and
//! encoded against modes reported by the runtime-owned VT.

const Key = @import("Key.zig");
const InputModesType = @import("telar-core").InputModes;
const std = @import("std");
const Encoding = @import("Encoding.zig");
const Char = @import("Char.zig");

pub fn encodeKey(buffer: []u8, key: Key, modes: InputModesType) ![]const u8 {
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

    const text = try textCharacter(key, char);
    try writer.writeAll(text.slice());

    return true;
}

fn textCharacter(key: Key, char: Char) !Char {
    if (key.mods.shift) {
        if (key.kitty) |codepoints| {
            if (codepoints.shifted) |shifted| {
                var bytes: [4]u8 = undefined;
                const scalar = std.math.cast(u21, shifted) orelse return error.UnencodableKey;
                const len = std.unicode.utf8Encode(scalar, &bytes) catch return error.UnencodableKey;

                return .init(bytes[0..len]);
            }
        }
    }

    return char;
}

// Host flags 7 deliver text as UTF-8 or a shifted alternate, not as a Kitty
// associated-text field. Reuse the legacy text choice, never the physical key.
fn associatedCodepoint(key: Key, encoding: Encoding) !?u21 {
    if (encoding.kitty_flags & 0b10000 == 0 or key.phase == .release or key.mods.ctrl or key.mods.alt) {
        return null;
    }

    const char = switch (key.code) {
        .char => |value| value,
        else => return null,
    };

    if (key.kitty) |codepoints| {
        if (codepoints.primary >= 57344 and codepoints.primary <= 63743) {
            return null;
        }
    }

    const text = try textCharacter(key, char);
    const codepoint = std.unicode.utf8Decode(text.slice()) catch return error.UnencodableKey;
    if (codepoint < 32 or (codepoint >= 127 and codepoint <= 159)) {
        return null;
    }

    return codepoint;
}

fn encodeKitty(writer: *std.Io.Writer, key: Key, encoding: Encoding) !void {
    const text = try associatedCodepoint(key, encoding);
    try writer.writeAll("\x1b[");
    try encodeKittyCodepoints(writer, key, encoding.kitty_flags);

    if (encoding.modifier != 1 or encoding.event != null or text != null) {
        try writer.print(";{d}", .{encoding.modifier});
    }

    if (encoding.event) |event| {
        try writer.print(":{d}", .{event});
    }

    if (text) |codepoint| {
        try writer.print(";{d}", .{codepoint});
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

fn encodeLegacyCharacter(writer: *std.Io.Writer, char: Char, key: Key) !void {
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

pub fn encodePaste(buffer: []u8, text: []const u8, modes: InputModesType) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    if (modes.bracketed_paste) {
        try writer.writeAll("\x1b[200~");
    }
    try writer.writeAll(text);
    if (modes.bracketed_paste) {
        try writer.writeAll("\x1b[201~");
    }
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
    if (alt) {
        try writer.writeByte(0x1b);
    }
    try writer.writeAll(bytes);
}
