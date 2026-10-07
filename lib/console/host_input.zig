//! Decodes what a host terminal sends: legacy, xterm and Kitty keys,
//! modifyOtherKeys, SGR mouse reports, bracketed paste, and the replies to
//! color, pixel-size, graphics and device-attribute queries.
//!
//! Terminal input is a stream, not a sequence of messages: `parse` reads one
//! event from the front of the bytes and reports an incomplete sequence with
//! a length of zero so the caller keeps them.
const keyinput = @import("keyinput");
const std = @import("std");
const KittyModifierEvent = @import("KittyModifierEvent.zig");

pub const Event = union(enum) {
    key: keyinput.Key,
    mouse: keyinput.Mouse,
    terminal_response: TerminalResponse,
    /// Bracketed paste boundaries.
    ///
    /// Between these, the characters that arrive were pasted rather than
    /// typed - and a newline among them is *text*, not the Enter key. Without
    /// the distinction, pasting three lines into a prompt runs three commands,
    /// which is both the classic annoyance and the reason a copied line from a
    /// web page can execute something.
    ///
    /// Delivered as markers with ordinary character events between them, not
    /// as one event carrying the payload. A slice would not survive the queue,
    /// and buffering an unbounded paste inside the parser would need an
    /// allocator on the keystroke path. The cost is that a large paste is many
    /// events; for the fields this drives, that is not a size anybody reaches.
    paste_start,
    paste_end,
    /// Bytes that arrived but do not yet form a complete sequence.
    incomplete,

    pub const Rgb8 = struct { r: u8, g: u8, b: u8 };

    pub const TerminalResponse = union(enum) {
        kitty_graphics: struct { image_id: u32, supported: bool },
        window_pixels: struct { width: u32, height: u32 },
        cell_pixels: struct { width: u32, height: u32 },
        mouse_pixels: struct { supported: bool },
        foreground_color: Rgb8,
        background_color: Rgb8,
        primary_device_attributes,
    };

};

const Parsed = @import("Parsed.zig");

/// Reads one event from the front of `input`.
///
/// Terminal input is a stream, not a sequence of messages: a mouse report can
/// arrive split across two reads, and an escape key is indistinguishable from
/// the start of an arrow key until the next byte does or does not come. This
/// reports `incomplete` with a length of zero and lets the caller keep the
/// bytes, which is the only honest thing to do.
/// Surfaces OSC 10/11 color reports and consumes other complete OSC replies.
fn parseOscReply(input: []const u8) Parsed {
    var end: usize = 2;
    var terminator_len: usize = 0;
    while (end < input.len) : (end += 1) {
        if (input[end] == 0x07) {
            terminator_len = 1;
            break;
        }
        if (input[end] == 0x1b) {
            if (end + 1 >= input.len) {
                return .{ .event = .incomplete, .len = 0 };
            }
            if (input[end + 1] == '\\') {
                terminator_len = 2;
                break;
            }
            return .{ .event = .incomplete, .len = end };
        }
    } else return .{ .event = .incomplete, .len = 0 };

    const length = end + terminator_len;
    const body = input[2..end];
    if (std.mem.startsWith(u8, body, "10;") or std.mem.startsWith(u8, body, "11;")) {
        if (parseOscColor(body[3..])) |color| {
            return .{ .event = .{ .terminal_response = if (body[1] == '0')
                .{ .foreground_color = color }
            else
                .{ .background_color = color } }, .len = length };
        }
    }

    return .{ .event = .incomplete, .len = length };
}

/// Accepts `rgb:RRRR/GGGG/BBBB` with 1..4 hex digits per channel, scaling to
/// eight bits from the leading digits.
fn parseOscColor(text: []const u8) ?Event.Rgb8 {
    if (!std.mem.startsWith(u8, text, "rgb:")) {
        return null;
    }
    var channels: [3]u8 = undefined;
    var iterator = std.mem.splitScalar(u8, text[4..], '/');
    for (&channels) |*channel| {
        const digits = iterator.next() orelse return null;
        if (digits.len == 0 or digits.len > 4) {
            return null;
        }
        for (digits) |digit| {
            _ = std.fmt.charToDigit(digit, 16) catch return null;
        }

        var value: u16 = 0;
        for (digits[0..@min(digits.len, 2)]) |digit| {
            value = value * 16 + (std.fmt.charToDigit(digit, 16) catch return null);
        }
        channel.* = if (digits.len == 1) @intCast(value * 17) else @intCast(value);
    }
    if (iterator.next() != null) {
        return null;
    }
    return .{ .r = channels[0], .g = channels[1], .b = channels[2] };
}

pub fn parse(input: []const u8) ?Parsed {
    if (input.len == 0) {
        return null;
    }

    if (input[0] != 0x1b) {
        return parseByte(input);
    }

    // A lone escape. Stream routers disambiguate it with a timeout; direct UI
    // callers that already own event framing can treat it as the key itself.
    if (input.len == 1) {
        return key(.escape, .{}, 1);
    }
    if (input[1] == '_') {
        return parseApc(input);
    }
    if (input[1] == ']') {
        return parseOscReply(input);
    }
    // SS3, which is what a terminal in application cursor mode sends for the
    // arrows and for Home and End. Ignoring it makes those keys dead in exactly
    // the terminals that use it.
    if (input[1] == 'O') {
        return parseSs3(input);
    }
    // Traditional terminals encode Alt+key as Escape followed by the key's
    // ordinary bytes. Once both bytes have arrived this is one modified key;
    // a stream reader still needs a timeout to distinguish a lone Escape.
    if (input[1] != '[') {
        return parseAlt(input);
    }
    if (input.len == 2) {
        return .{ .event = .incomplete, .len = 0 };
    }

    if (input[2] == '<') {
        return parseMouse(input);
    }

    // Unmodified arrows, and the two forms of Home and End that need no
    // parameters.
    switch (input[2]) {
        'A' => return physicalKey(.{ .code = .up }, 3),
        'B' => return physicalKey(.{ .code = .down }, 3),
        'C' => return physicalKey(.{ .code = .right }, 3),
        'D' => return physicalKey(.{ .code = .left }, 3),
        'H' => return physicalKey(.{ .code = .home }, 3),
        'F' => return physicalKey(.{ .code = .end }, 3),
        'Z' => return key(.back_tab, .{}, 3),
        else => {},
    }

    // A parameterised CSI: `ESC [ p1 ; p2 final`. Find the final byte first,
    // because everything else depends on having the whole sequence.
    var final: usize = 2;
    while (final < input.len and !(input[final] >= 0x40 and input[final] <= 0x7e)) {
        // ECMA-48: a new ESC aborts the sequence in progress. Consume only
        // the dead prefix, so the aborting sequence parses from its own
        // introducer instead of leaking its final bytes as typed characters.
        if (input[final] == 0x1b) {
            return .{ .event = .incomplete, .len = final };
        }
        final += 1;
    }
    if (final == input.len) {
        return .{ .event = .incomplete, .len = 0 };
    }

    var params: [3]u32 = .{ 0, 0, 0 };
    var count: usize = 0;
    var index: usize = 2;
    while (index < final) : (index += 1) {
        if (input[index] == ';') {
            count += 1;
            if (count == params.len) {
                break;
            }
            continue;
        }
        if (input[index] < '0' or input[index] > '9') {
            break;
        }
        params[count] = params[count] *| 10 +| (input[index] - '0');
    }
    const length = final + 1;

    if (input[final] == 'y' and
        std.mem.startsWith(u8, input[0..length], "\x1b[?1016;") and
        final >= 2 and input[final - 1] == '$')
    {
        const prefix_len = "\x1b[?1016;".len;
        const status = std.fmt.parseInt(u8, input[prefix_len .. final - 1], 10) catch 0;
        return .{ .event = .{ .terminal_response = .{ .mouse_pixels = .{
            .supported = status != 0,
        } } }, .len = length };
    }

    switch (input[final]) {
        // Kitty's disambiguation mode reports modified text keys as CSI-u,
        // keeping Ctrl+H distinct from Backspace and Ctrl+J from Enter.
        'u' => return parseKittyKey(input[2..final], length) orelse
            .{ .event = .incomplete, .len = length },
        // `ESC [ 1 ; modifier:event X` - a Kitty cursor-key lifecycle.
        'A' => return parseCursorKey(input[2..final], .up, length) orelse
            .{ .event = .incomplete, .len = length },
        'B' => return parseCursorKey(input[2..final], .down, length) orelse
            .{ .event = .incomplete, .len = length },
        'C' => return parseCursorKey(input[2..final], .right, length) orelse
            .{ .event = .incomplete, .len = length },
        'D' => return parseCursorKey(input[2..final], .left, length) orelse
            .{ .event = .incomplete, .len = length },
        'H' => return parseCursorKey(input[2..final], .home, length) orelse
            .{ .event = .incomplete, .len = length },
        'F' => return parseCursorKey(input[2..final], .end, length) orelse
            .{ .event = .incomplete, .len = length },
        // `ESC [ n ~` - the numbered keys, and the paste brackets.
        '~' => return parseTildeKey(input[2..final], length) orelse
            .{ .event = .incomplete, .len = length },
        't' => switch (params[0]) {
            4 => return .{ .event = .{ .terminal_response = .{ .window_pixels = .{
                .width = params[2],
                .height = params[1],
            } } }, .len = length },
            6 => return .{ .event = .{ .terminal_response = .{ .cell_pixels = .{
                .width = params[2],
                .height = params[1],
            } } }, .len = length },
            else => {},
        },
        'c' => return .{
            .event = .{ .terminal_response = .primary_device_attributes },
            .len = length,
        },
        else => {},
    }

    // Some other CSI. Skip it rather than choking: a terminal sends responses
    // nobody asked for, and dropping one unknown sequence beats desynchronising
    // the whole stream.
    return .{ .event = .incomplete, .len = length };
}

fn parseKittyKey(body: []const u8, length: usize) ?Parsed {
    var fields = std.mem.splitScalar(u8, body, ';');
    const codepoint_text = fields.next() orelse return null;
    const modifier_text = fields.next();
    if (fields.next() != null) {
        return null;
    }

    const codepoints = parseKittyCodepoints(codepoint_text) orelse return null;
    const modifier_event = parseKittyModifierEvent(modifier_text) orelse return null;
    const code = codepointCode(codepoints.primary) orelse return null;
    const mods = parseKeyModifiers(modifier_event.modifier) orelse return null;

    return .{
        .event = .{ .key = .{
            .code = code,
            .mods = mods,
            .phase = modifier_event.event,
            .physical = .{ .value = codepoints.base orelse codepoints.primary },
            .kitty = codepoints,
        } },
        .len = length,
    };
}

fn parseCursorKey(body: []const u8, code: keyinput.Key.Code, length: usize) ?Parsed {
    const parameters = parseFunctionKeyParameters(body) orelse return null;
    if (parameters.number != 1) {
        return null;
    }

    const mods = parseKeyModifiers(parameters.modifier_event.modifier) orelse return null;

    return physicalKey(.{
        .code = code,
        .mods = mods,
        .phase = parameters.modifier_event.event,
    }, length);
}

fn parseTildeKey(body: []const u8, length: usize) ?Parsed {
    if (std.mem.startsWith(u8, body, "27;")) {
        return parseModifyOtherKeys(body, length);
    }

    const parameters = parseFunctionKeyParameters(body) orelse return null;
    if (parameters.modifier_event.event == .press) {
        switch (parameters.number) {
            200 => return .{ .event = .paste_start, .len = length },
            201 => return .{ .event = .paste_end, .len = length },
            else => {},
        }
    }

    const code: keyinput.Key.Code = switch (parameters.number) {
        1, 7 => .home,
        3 => .delete,
        5 => .page_up,
        6 => .page_down,
        4, 8 => .end,
        else => return null,
    };
    const mods = parseKeyModifiers(parameters.modifier_event.modifier) orelse return null;

    return physicalKey(.{
        .code = code,
        .mods = mods,
        .phase = parameters.modifier_event.event,
    }, length);
}

fn parseFunctionKeyParameters(body: []const u8) ?FunctionKeyParameters {
    var fields = std.mem.splitScalar(u8, body, ';');
    const number_text = fields.next() orelse return null;
    if (number_text.len == 0) {
        return null;
    }

    const number = std.fmt.parseUnsigned(u32, number_text, 10) catch return null;
    const modifier_event = parseKittyModifierEvent(fields.next()) orelse return null;
    if (fields.next() != null) {
        return null;
    }

    return .{ .number = number, .modifier_event = modifier_event };
}

fn parseKittyCodepoints(field: []const u8) ?keyinput.Key.KittyCodepoints {
    var values = std.mem.splitScalar(u8, field, ':');
    const primary = values.next() orelse return null;
    if (primary.len == 0) {
        return null;
    }

    const codepoint = parseUnicodeCodepoint(primary) orelse return null;
    const shifted_text = values.next() orelse return .{ .primary = codepoint };
    const base_text = values.next();
    if (values.next() != null) {
        return null;
    }
    if (shifted_text.len == 0 and base_text == null) {
        return null;
    }
    const shifted = if (shifted_text.len == 0)
        null
    else
        parseUnicodeCodepoint(shifted_text) orelse return null;
    const base = if (base_text) |value| parsed: {
        if (value.len == 0) {
            return null;
        }

        break :parsed parseUnicodeCodepoint(value) orelse return null;
    } else null;

    return .{ .primary = codepoint, .shifted = shifted, .base = base };
}

fn parseUnicodeCodepoint(text: []const u8) ?u32 {
    const value = std.fmt.parseUnsigned(u32, text, 10) catch return null;
    const scalar = std.math.cast(u21, value) orelse return null;
    var bytes: [4]u8 = undefined;
    _ = std.unicode.utf8Encode(scalar, &bytes) catch return null;

    return value;
}

fn parseKittyModifierEvent(field: ?[]const u8) ?KittyModifierEvent {
    const value = field orelse return .{ .modifier = 1, .event = .press };
    var parts = std.mem.splitScalar(u8, value, ':');
    const modifier_text = parts.next() orelse return null;
    if (modifier_text.len == 0) {
        return null;
    }

    const modifier = std.fmt.parseUnsigned(u32, modifier_text, 10) catch return null;
    const event_text = parts.next() orelse return .{ .modifier = modifier, .event = .press };
    if (event_text.len == 0 or parts.next() != null) {
        return null;
    }

    const event_value = std.fmt.parseUnsigned(u2, event_text, 10) catch return null;
    const event: keyinput.Key.Phase = switch (event_value) {
        1 => .press,
        2 => .repeat,
        3 => .release,
        else => return null,
    };
    return .{ .modifier = modifier, .event = event };
}

fn parseModifyOtherKeys(body: []const u8, length: usize) ?Parsed {
    var fields = std.mem.splitScalar(u8, body, ';');
    if (!std.mem.eql(u8, fields.next() orelse return null, "27")) {
        return null;
    }
    const modifier = std.fmt.parseUnsigned(u32, fields.next() orelse return null, 10) catch return null;
    const codepoint = std.fmt.parseUnsigned(u32, fields.next() orelse return null, 10) catch return null;
    if (fields.next() != null) {
        return null;
    }
    return codepointKey(codepoint, modifier, length);
}

fn codepointKey(codepoint: u32, modifier: u32, length: usize) ?Parsed {
    const mods = parseKeyModifiers(modifier) orelse return null;
    const code = codepointCode(codepoint) orelse return null;

    return key(code, mods, length);
}

fn codepointCode(codepoint: u32) ?keyinput.Key.Code {
    return switch (codepoint) {
        9 => .tab,
        13 => .enter,
        27 => .escape,
        127 => .backspace,
        else => character: {
            const scalar = std.math.cast(u21, codepoint) orelse return null;
            var bytes: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(scalar, &bytes) catch return null;
            break :character .{ .char = .init(bytes[0..len]) };
        },
    };
}

fn parseKeyModifiers(modifier: u32) ?keyinput.Key.Mods {
    if (modifier == 0) {
        return null;
    }

    const modifier_bits = modifier - 1;
    const unsupported_modifier_bits = modifier_bits & ~@as(u32, 0b1100_0111);
    if (unsupported_modifier_bits != 0) {
        return null;
    }

    return modsOf((modifier_bits & 0b111) + 1);
}

fn parseApc(input: []const u8) Parsed {
    var end: usize = 2;
    while (end + 1 < input.len) : (end += 1) {
        if (input[end] != 0x1b or input[end + 1] != '\\') {
            continue;
        }
        const length = end + 2;
        const content = input[2..end];
        if (content.len < 2 or content[0] != 'G') {
            return .{ .event = .incomplete, .len = length };
        }
        const separator = std.mem.indexOfScalar(u8, content, ';') orelse
            return .{ .event = .incomplete, .len = length };
        var image_id: u32 = 0;
        var fields = std.mem.splitScalar(u8, content[1..separator], ',');
        while (fields.next()) |field| {
            if (!std.mem.startsWith(u8, field, "i=")) {
                continue;
            }
            image_id = std.fmt.parseInt(u32, field[2..], 10) catch 0;
        }
        if (image_id == 0) {
            return .{ .event = .incomplete, .len = length };
        }
        const status = content[separator + 1 ..];
        return .{
            .event = .{ .terminal_response = .{ .kitty_graphics = .{
                .image_id = image_id,
                .supported = std.mem.eql(u8, status, "OK"),
            } } },
            .len = length,
        };
    }
    return .{ .event = .incomplete, .len = 0 };
}

fn parseByte(input: []const u8) ?Parsed {
    switch (input[0]) {
        // LF is Ctrl+J, also used by host mappings for multiline prompts.
        // Collapsing it into Enter would turn it into CR when re-encoded.
        '\r' => return key(.enter, .{}, 1),
        '\t' => return key(.tab, .{}, 1),
        // Both codes terminals send for the key marked Backspace.
        0x7f, 0x08 => return key(.backspace, .{}, 1),
        else => {},
    }

    // Control characters: Ctrl+A is 1, and so on up to Ctrl+Z. Reported as the
    // letter with a modifier rather than as its own kind of key, so a handler
    // that wants Ctrl+C and one that wants "c" read the same way.
    if (input[0] == 0) {
        return key(.{ .char = .init(" ") }, .{ .ctrl = true }, 1);
    }
    if (input[0] >= 1 and input[0] <= 26) {
        return key(.{ .char = .init(&.{input[0] + 'a' - 1}) }, .{ .ctrl = true }, 1);
    }
    if (input[0] >= 0x1c and input[0] <= 0x1f) {
        const controls = "\\]^_";
        return key(.{ .char = .init(controls[input[0] - 0x1c ..][0..1]) }, .{ .ctrl = true }, 1);
    }

    const length = std.unicode.utf8ByteSequenceLength(input[0]) catch 1;
    if (input.len < length) {
        return .{ .event = .incomplete, .len = 0 };
    }
    return key(.{ .char = .init(input[0..length]) }, .{}, length);
}

fn parseAlt(input: []const u8) Parsed {
    if (input[1] == 0x1b) {
        // ESC ESC: legacy terminals prefix a whole CSI or SS3 sequence with
        // ESC for a modified key, so Alt+Up arrives as `ESC ESC [ A`. Only
        // the third byte disambiguates that from Alt+Escape.
        if (input.len == 2) {
            return .{ .event = .incomplete, .len = 0 };
        }
        if (input[2] == '[' or input[2] == 'O') {
            const parsed = parse(input[1..]) orelse unreachable;
            if (parsed.len == 0) {
                return parsed;
            }
            return switch (parsed.event) {
                .key => |pressed| altKey(pressed, parsed.len + 1),
                else => .{ .event = .incomplete, .len = parsed.len + 1 },
            };
        }
        return key(.escape, .{ .alt = true }, 2);
    }
    const parsed = parseByte(input[1..]) orelse unreachable;
    if (parsed.len == 0) {
        return parsed;
    }
    return switch (parsed.event) {
        .key => |pressed| altKey(pressed, parsed.len + 1),
        else => .{ .event = .incomplete, .len = parsed.len + 1 },
    };
}

/// `ESC O X`, application cursor mode.
fn parseSs3(input: []const u8) ?Parsed {
    if (input.len < 3) {
        return .{ .event = .incomplete, .len = 0 };
    }
    return switch (input[2]) {
        'A' => physicalKey(.{ .code = .up }, 3),
        'B' => physicalKey(.{ .code = .down }, 3),
        'C' => physicalKey(.{ .code = .right }, 3),
        'D' => physicalKey(.{ .code = .left }, 3),
        'H' => physicalKey(.{ .code = .home }, 3),
        'F' => physicalKey(.{ .code = .end }, 3),
        else => .{ .event = .incomplete, .len = 3 },
    };
}

fn key(code: keyinput.Key.Code, mods: keyinput.Key.Mods, length: usize) Parsed {
    return .{ .event = .{ .key = .{ .code = code, .mods = mods } }, .len = length };
}

fn physicalKey(pressed: keyinput.Key, length: usize) Parsed {
    var leased = pressed;
    leased.physical = physicalIdentity(pressed.code);

    return .{
        .event = .{ .key = leased },
        .len = length,
    };
}

fn altKey(pressed: keyinput.Key, length: usize) Parsed {
    var modified = pressed;
    modified.mods.alt = true;

    return .{ .event = .{ .key = modified }, .len = length };
}

fn physicalIdentity(code: keyinput.Key.Code) keyinput.Key.Physical {
    return switch (code) {
        .char => |char| .{ .value = std.unicode.utf8Decode(char.slice()) catch 0 },
        .tab, .back_tab => .{ .value = @as(u32, 0x110000) + @intFromEnum(std.meta.Tag(keyinput.Key.Code).tab) },
        else => .{ .value = @as(u32, 0x110000) + @intFromEnum(std.meta.activeTag(code)) },
    };
}

/// The modifier parameter terminals send: one plus a bit per held modifier.
///
/// Zero means the parameter was absent, which is not the same as "no
/// modifiers" arithmetically - subtracting one from it would set every bit.
fn modsOf(param: u32) keyinput.Key.Mods {
    if (param == 0) {
        return .{};
    }
    const bits = param - 1;
    return .{
        .shift = bits & 1 != 0,
        .alt = bits & 2 != 0,
        .ctrl = bits & 4 != 0,
    };
}

/// SGR mouse reporting, `ESC [ < button ; column ; row M|m`.
///
/// Worth preferring over the older encoding because coordinates are decimal
/// rather than single bytes, so it keeps working past column 223 - which any
/// full screen terminal passes.
fn parseMouse(input: []const u8) ?Parsed {
    var index: usize = 3;
    var fields: [3]u32 = .{ 0, 0, 0 };
    var field: usize = 0;

    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte >= '0' and byte <= '9') {
            fields[field] = fields[field] *| 10 +| (byte - '0');
            continue;
        }
        if (byte == ';') {
            field += 1;
            if (field >= fields.len) {
                return .{ .event = .incomplete, .len = index + 1 };
            }
            continue;
        }
        // A new ESC aborts the report; keep it for the next parse.
        if (byte == 0x1b) {
            return .{ .event = .incomplete, .len = index };
        }
        if (byte != 'M' and byte != 'm') {
            return .{ .event = .incomplete, .len = index + 1 };
        }

        const button = fields[0];
        // Terminals count from one; everything above this counts from zero.
        const x = fields[1] -| 1;
        const y = fields[2] -| 1;

        const kind: keyinput.Mouse.Kind = if (button & 64 != 0)
            (if (button & 1 == 0) .scroll_up else .scroll_down)
        else if (button & 32 != 0)
            (if (button & 3 == 3) .move else .drag)
        else if (byte == 'm')
            .release
        else
            .press;

        return .{ .event = .{ .mouse = .{
            .x = std.math.cast(u16, x) orelse std.math.maxInt(u16),
            .y = std.math.cast(u16, y) orelse std.math.maxInt(u16),
            .raw_x = x,
            .raw_y = y,
            .kind = kind,
            .button = @truncate(button),
        } }, .len = index + 1 };
    }
    return .{ .event = .incomplete, .len = 0 };
}

const FunctionKeyParameters = struct {
    number: u32,
    modifier_event: KittyModifierEvent,
};
