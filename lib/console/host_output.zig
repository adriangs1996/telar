//! Escape sequences a full-screen program writes to its host terminal: SGR
//! styles, cursor moves, OSC 52 clipboard writes and OSC 9 notifications.
//! Bytes in and bytes out; nothing here makes a system call.
const cellgrid = @import("cellgrid");
const std = @import("std");

pub fn writeStyle(w: *std.Io.Writer, style: cellgrid.Style) !void {
    // Reset first: turning attributes off individually needs one code per
    // attribute and a memory of which were on. Resetting costs four bytes.
    try w.writeAll("\x1b[0");
    const f = style.flags;
    if (f.bold) {
        try w.writeAll(";1");
    }
    if (f.faint) {
        try w.writeAll(";2");
    }
    if (f.italic) {
        try w.writeAll(";3");
    }
    if (f.blink) {
        try w.writeAll(";5");
    }
    if (f.inverse) {
        try w.writeAll(";7");
    }
    if (f.invisible) {
        try w.writeAll(";8");
    }
    if (f.strikethrough) {
        try w.writeAll(";9");
    }
    if (f.overline) {
        try w.writeAll(";53");
    }
    // SGR 4:n rather than plain 4, so a curly underline stays curly. Terminals
    // that do not know the sub-parameter form fall back to a plain underline,
    // which is the right degradation.
    if (f.underline != .none) {
        try w.print(";4:{d}", .{@intFromEnum(f.underline)});
    }
    try writeColor(w, style.fg, .foreground);
    try writeColor(w, style.bg, .background);
    // Only when there is an underline to colour. Emitting SGR 58 unconditionally
    // costs bytes on every run and confuses terminals that parse it loosely.
    if (f.underline != .none) {
        try writeColor(w, style.underline_color, .underline);
    }
    try w.writeAll("m");
}

// ---------------------------------------------------------------------------
// The clipboard
// ---------------------------------------------------------------------------

/// The largest payload we will try to send.
///
/// There is no standard limit, and terminals pick their own; a sequence past
/// whatever a given one accepts is silently ignored, which looks exactly like a
/// copy that did nothing. Refusing loudly at a known size is better than
/// succeeding on some machines.
pub const max_clipboard_bytes = 64 * 1024;

pub const ClipboardError = error{TooLarge};

/// Puts `payload` on the system clipboard with OSC 52.
///
/// The point of doing it this way rather than shelling out to `pbcopy` or
/// `xclip`: OSC 52 is *bytes on the same stream as everything else*, so it
/// works through SSH, through tmux, and inside a container, none of which have
/// access to the clipboard of the machine the human is sitting at.
///
/// Two things a caller should know. Some terminals ship with this disabled,
/// because a program that can write your clipboard is a program that can put a
/// command there - so a copy can legitimately do nothing and there is no reply
/// to check. And that is why the terminal's own Shift-drag selection has to
/// keep working: it is the fallback for exactly this case.
/// Writes one OSC 9 host notification. Callers pass pre-sanitized text with
/// no control bytes.
///
/// ```zig
/// try writeHostNotification(writer, "Agent done", "Claude in pane 2");
/// ```
pub fn writeHostNotification(w: *std.Io.Writer, title: []const u8, message: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("\x1b]9;");
    try w.writeAll(title);
    if (message.len != 0) {
        try w.writeAll(": ");
        try w.writeAll(message);
    }
    try w.writeAll("\x07");
}

pub fn writeClipboard(w: *std.Io.Writer, payload: []const u8) (ClipboardError || std.Io.Writer.Error)!void {
    if (payload.len > max_clipboard_bytes) {
        return error.TooLarge;
    }

    // `c` is the selection name: the clipboard proper rather than the X11
    // primary selection, which is the one that pastes on middle click and is
    // not what a user means by "copy".
    try w.writeAll("\x1b]52;c;");

    const Encoder = std.base64.standard.Encoder;
    var chunk: [3 * 512]u8 = undefined;
    var encoded: [4 * 512]u8 = undefined;
    var at: usize = 0;
    while (at < payload.len) {
        // In multiples of three, so each chunk encodes independently: base64
        // pads at the end of its input, and padding in the middle of a stream
        // decodes to garbage.
        const take = @min(chunk.len, payload.len - at);
        @memcpy(chunk[0..take], payload[at..][0..take]);
        try w.writeAll(Encoder.encode(encoded[0..Encoder.calcSize(take)], chunk[0..take]));
        at += take;
    }

    // BEL rather than ST: both terminate an OSC, and BEL is the form every
    // terminal understands.
    try w.writeAll("\x07");
}

/// SGR parameters introducing an extended color for each styled layer.
const ColorLayer = enum(u8) {
    foreground = 38,
    background = 48,
    underline = 58,
};

/// Longest extended color parameter: `;38;2;255;255;255`.
const max_color_len = 17;

/// Longest cursor position: `ESC [ 4294967295 ; 4294967295 H`.
const max_cursor_position_len = 2 + 10 + 1 + 10 + 1;

fn writeColor(w: *std.Io.Writer, color: cellgrid.Color, comptime layer: ColorLayer) !void {
    const prefix = std.fmt.comptimePrint(";{d}", .{@intFromEnum(layer)});
    const channels = color.value;
    if (color.kind == .default) {
        return;
    }

    if (w.unusedCapacityLen() < max_color_len) {
        switch (color.kind) {
            .default => unreachable,
            .indexed => try w.print(prefix ++ ";5;{d}", .{channels[0]}),
            .rgb => try w.print(prefix ++ ";2;{d};{d};{d}", .{ channels[0], channels[1], channels[2] }),
        }

        return;
    }

    const out = w.unusedCapacitySlice();
    var len: usize = 0;
    len += appendLiteral(out[len..], prefix);
    if (color.kind == .indexed) {
        len += appendLiteral(out[len..], ";5;");
        len += appendDecimal(out[len..], channels[0]);
    } else {
        len += appendLiteral(out[len..], ";2;");
        len += appendDecimal(out[len..], channels[0]);
        len += appendLiteral(out[len..], ";");
        len += appendDecimal(out[len..], channels[1]);
        len += appendLiteral(out[len..], ";");
        len += appendDecimal(out[len..], channels[2]);
    }

    w.advance(len);
}

/// Moves the host cursor to a one-based `row` and `column`, formatting the
/// digits in place instead of through `std.fmt`: every run of changed cells
/// starts with one. Example: `try console.writeCursorPosition(w, .{ y + 1, x + 1 });`
pub fn writeCursorPosition(w: *std.Io.Writer, position: [2]u32) !void {
    if (w.unusedCapacityLen() < max_cursor_position_len) {
        try w.print("\x1b[{d};{d}H", .{ position[0], position[1] });
        return;
    }

    const out = w.unusedCapacitySlice();
    var len = appendLiteral(out, "\x1b[");
    len += appendDecimal(out[len..], position[0]);
    len += appendLiteral(out[len..], ";");
    len += appendDecimal(out[len..], position[1]);
    len += appendLiteral(out[len..], "H");
    w.advance(len);
}

fn appendLiteral(out: []u8, comptime literal: []const u8) usize {
    out[0..literal.len].* = literal[0..literal.len].*;
    return literal.len;
}

fn appendDecimal(out: []u8, value: u32) usize {
    var digits: [10]u8 = undefined;
    var remaining = value;
    var start: usize = digits.len;
    while (true) {
        start -= 1;
        digits[start] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
        if (remaining == 0) {
            break;
        }
    }

    const len = digits.len - start;
    @memcpy(out[0..len], digits[start..]);
    return len;
}

test "direct escape formatting matches std.fmt at every boundary" {
    var direct_storage: [64]u8 = undefined;
    var formatted_storage: [64]u8 = undefined;
    for ([_]u32{ 0, 1, 9, 10, 99, 100, 999, 65535, 65536, std.math.maxInt(u32) }) |row| {
        for ([_]u32{ 1, 10, 255, 65536 }) |column| {
            var direct = std.Io.Writer.fixed(&direct_storage);
            var formatted = std.Io.Writer.fixed(&formatted_storage);
            try writeCursorPosition(&direct, .{ row, column });
            try formatted.print("\x1b[{d};{d}H", .{ row, column });
            try std.testing.expectEqualStrings(formatted.buffered(), direct.buffered());
        }
    }

    for ([_]cellgrid.Color{ .default, .indexed(0), .indexed(7), .indexed(255), .rgb(.{ 0, 9, 10 }), .rgb(.{ 255, 255, 255 }) }) |color| {
        var direct = std.Io.Writer.fixed(&direct_storage);
        try writeColor(&direct, color, .underline);
        var formatted = std.Io.Writer.fixed(&formatted_storage);
        switch (color.kind) {
            .default => {},
            .indexed => try formatted.print(";58;5;{d}", .{color.value[0]}),
            .rgb => try formatted.print(";58;2;{d};{d};{d}", .{ color.value[0], color.value[1], color.value[2] }),
        }

        try std.testing.expectEqualStrings(formatted.buffered(), direct.buffered());
    }
}

test "direct escape formatting falls back near the end of a fixed buffer" {
    var storage: [9]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeCursorPosition(&writer, .{ 12, 34 });
    try std.testing.expectEqualStrings("\x1b[12;34H", writer.buffered());
    try std.testing.expectError(error.WriteFailed, writeCursorPosition(&writer, .{ 1, 1 }));
}

test "a copy is one osc 52 sequence with the text in base64" {
    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeClipboard(&w, "hola");

    // `c` is the clipboard proper, not the X11 primary selection - which pastes
    // on middle click and is not what anybody means by "copy".
    try std.testing.expectEqualStrings("\x1b]52;c;aG9sYQ==\x07", w.buffered());
}

test "a payload longer than one chunk still decodes" {
    // Encoded in pieces to bound the stack, and base64 pads at the end of its
    // input - so a chunk that is not a multiple of three would put padding in
    // the middle of the stream and everything after it would decode to garbage.
    var payload: [4000]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @intCast('a' + i % 26);

    var out: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeClipboard(&w, &payload);

    const written = w.buffered();
    const body = written["\x1b]52;c;".len .. written.len - 1];
    const Decoder = std.base64.standard.Decoder;
    var decoded: [4000]u8 = undefined;
    try Decoder.decode(&decoded, body);
    try std.testing.expectEqualSlices(u8, &payload, &decoded);
}

test "an oversized copy fails rather than silently doing nothing" {
    // Terminals ignore a sequence past whatever size they accept, with no
    // reply. Succeeding here would produce a copy that works on one machine and
    // not another, with nothing to look at.
    var out: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    var huge: [max_clipboard_bytes + 1]u8 = undefined;
    @memset(&huge, 'x');
    try std.testing.expectError(error.TooLarge, writeClipboard(&w, &huge));
}
