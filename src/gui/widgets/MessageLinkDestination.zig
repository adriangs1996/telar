//! Bounded display decoding for Markdown destinations, without URL resolution.
//! Named entities support amp, quot, apos, lt and gt; unknown names stay literal.
const std = @import("std");
const Destination = @This();

pub const capacity = 4096;
buffer: [capacity]u8 = undefined,
len: u16 = 0,

/// Decodes Markdown escapes and basic/numeric entities into owned UTF-8.
/// Rejects controls, invalid UTF-8 and oversized output. Percent escapes remain.
/// Example: `const destination = try Destination.init(span.destination.?);`
pub fn init(raw: []const u8) !Destination {
    if (raw.len > capacity or !std.unicode.utf8ValidateSlice(raw)) {
        return error.InvalidLinkDestination;
    }

    var result: Destination = .{};
    var at: usize = 0;
    while (at < raw.len) {
        if (raw[at] == '\\' and at + 1 < raw.len and std.ascii.isPunctuation(raw[at + 1])) {
            try result.append(raw[at + 1 ..][0..1]);
            at += 2;
            continue;
        }

        if (raw[at] == '&') {
            const remaining = raw[at..@min(raw.len, at + 16)];
            if (std.mem.indexOfScalar(u8, remaining, ';')) |end| {
                if (entity(remaining[1..end])) |point| {
                    var bytes: [4]u8 = undefined;
                    const count = try std.unicode.utf8Encode(point, &bytes);
                    try result.append(bytes[0..count]);
                    at += end + 1;
                    continue;
                }
            }
        }

        try result.append(raw[at..][0..1]);
        at += 1;
    }

    return result;
}

/// Borrows the normalized display text until this value is changed or destroyed.
/// Example: `try drawTooltip(destination.text());`
pub fn text(destination: *const Destination) []const u8 {
    return destination.buffer[0..destination.len];
}

fn append(destination: *Destination, bytes: []const u8) !void {
    for (bytes) |byte| {
        if (byte < 32 or byte == 127) {
            return error.InvalidLinkDestination;
        }
    }

    if (bytes.len > capacity - destination.len) {
        return error.InvalidLinkDestination;
    }

    @memcpy(destination.buffer[destination.len..][0..bytes.len], bytes);
    destination.len += @intCast(bytes.len);
}

fn entity(name: []const u8) ?u21 {
    const names = [_][]const u8{ "amp", "quot", "apos", "lt", "gt" };
    const values = [_]u21{ '&', '"', '\'', '<', '>' };
    for (names, values) |expected, value| {
        if (std.mem.eql(u8, name, expected)) {
            return value;
        }
    }

    if (name.len < 2 or name[0] != '#') {
        return null;
    }

    const hex = name[1] == 'x' or name[1] == 'X';
    const digits = name[if (hex) @as(usize, 2) else 1..];
    if (digits.len == 0 or digits.len > (if (hex) @as(usize, 6) else 7)) {
        return null;
    }

    for (digits) |digit| {
        if (!(if (hex) std.ascii.isHex(digit) else std.ascii.isDigit(digit))) {
            return null;
        }
    }

    const value = std.fmt.parseInt(u32, digits, if (hex) 16 else 10) catch return null;
    if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) {
        return 0xfffd;
    }

    return @intCast(value);
}

test "Markdown destination decoding is bounded owned text with no URL resolution" {
    const value = try Destination.init("../my\\(file\\).zig?x=1&amp;y=&#x1F642;&quot;&apos;&lt;&gt;");
    try std.testing.expectEqualStrings("../my(file).zig?x=1&y=🙂\"'<>", value.text());
    const literal = try Destination.init("https://example.com/%20?x=&unknown;&bare\\path");
    try std.testing.expectEqualStrings("https://example.com/%20?x=&unknown;&bare\\path", literal.text());
    const escaped = try Destination.init("x\\&amp;");
    try std.testing.expectEqualStrings("x&amp;", escaped.text());
    const decimal = try Destination.init("&#65;&#0;&#xD800;&#9999999;");
    try std.testing.expectEqualStrings("A���", decimal.text());
}

test "Markdown destination decoding rejects controls invalid encoding and oversized source" {
    try std.testing.expectError(error.InvalidLinkDestination, Destination.init("x\x00y"));
    try std.testing.expectError(error.InvalidLinkDestination, Destination.init("x&#10;y"));
    try std.testing.expectError(error.InvalidLinkDestination, Destination.init("x&#x7f;y"));
    try std.testing.expectError(error.InvalidLinkDestination, Destination.init("x\xffy"));
    try std.testing.expectError(error.InvalidLinkDestination, Destination.init(&(@as([capacity + 1]u8, @splat('x')))));
    const exact = try Destination.init(&(@as([capacity]u8, @splat('x'))));
    try std.testing.expectEqual(capacity, exact.text().len);
}
