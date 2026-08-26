//! Semantic child-input encoding.
//!
//! Host-terminal bytes never cross this boundary. Keys are parsed first and
//! encoded against modes reported by the runtime-owned VT.

const std = @import("std");
const core = @import("telar-core");
const term = @import("term.zig");

pub const Key = term.Event.Key;
pub const Modes = core.schema.frame.InputModes;

pub fn encodeKey(buffer: []u8, key: Key, modes: Modes) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    const modifier = 1 + @as(u8, @intFromBool(key.mods.shift)) +
        2 * @as(u8, @intFromBool(key.mods.alt)) +
        4 * @as(u8, @intFromBool(key.mods.ctrl));

    switch (key.code) {
        .char => |char| {
            if (key.mods.alt) try writer.writeByte(0x1b);
            if (key.mods.ctrl) {
                if (char.len != 1) return error.UnencodableControlKey;
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
            } else {
                try writer.writeAll(char.slice());
            }
        },
        .up => try encodeCursor(&writer, 'A', modifier, modes.cursor_keys),
        .down => try encodeCursor(&writer, 'B', modifier, modes.cursor_keys),
        .right => try encodeCursor(&writer, 'C', modifier, modes.cursor_keys),
        .left => try encodeCursor(&writer, 'D', modifier, modes.cursor_keys),
        .home => try encodeCursor(&writer, 'H', modifier, modes.cursor_keys),
        .end => try encodeCursor(&writer, 'F', modifier, modes.cursor_keys),
        .delete => if (modifier == 1)
            try writer.writeAll("\x1b[3~")
        else
            try writer.print("\x1b[3;{d}~", .{modifier}),
        .page_up => if (modifier == 1)
            try writer.writeAll("\x1b[5~")
        else
            try writer.print("\x1b[5;{d}~", .{modifier}),
        .page_down => if (modifier == 1)
            try writer.writeAll("\x1b[6~")
        else
            try writer.print("\x1b[6;{d}~", .{modifier}),
        .enter => try withAlt(&writer, key.mods.alt, "\r"),
        .escape => try writer.writeByte(0x1b),
        .backspace => try withAlt(&writer, key.mods.alt, "\x7f"),
        .tab => try withAlt(&writer, key.mods.alt, "\t"),
        .back_tab => try writer.writeAll("\x1b[Z"),
    }
    return writer.buffered();
}

pub fn encodePaste(buffer: []u8, text: []const u8, modes: Modes) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    if (modes.bracketed_paste) try writer.writeAll("\x1b[200~");
    try writer.writeAll(text);
    if (modes.bracketed_paste) try writer.writeAll("\x1b[201~");
    return writer.buffered();
}

fn encodeCursor(writer: *std.Io.Writer, final: u8, modifier: u8, application: bool) !void {
    if (modifier != 1) {
        try writer.print("\x1b[1;{d}{c}", .{ modifier, final });
    } else if (application) {
        try writer.writeAll("\x1bO");
        try writer.writeByte(final);
    } else {
        try writer.writeAll("\x1b[");
        try writer.writeByte(final);
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
