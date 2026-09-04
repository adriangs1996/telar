//! Pure recognition of supported URI text. Terminal coordinates, OSC 8
//! metadata and opener policy belong to the process-specific adapters.

const std = @import("std");

pub const max_uri_bytes = 4096;

pub const Scheme = enum {
    file,
    http,
    https,
};

pub const Match = struct {
    scheme: Scheme,
    start: usize,
    end: usize,

    /// Returns the matched URI from the source passed to `extractAt`.
    ///
    /// ```zig
    /// const uri = match.text(line);
    /// ```
    pub fn text(match: Match, source: []const u8) []const u8 {
        return source[match.start..match.end];
    }
};

const Prefix = struct {
    text: []const u8,
    scheme: Scheme,
};

const prefixes = [_]Prefix{
    .{ .text = "https://", .scheme = .https },
    .{ .text = "http://", .scheme = .http },
    .{ .text = "file://", .scheme = .file },
};

/// Classifies one complete supported URI after validating its structure.
///
/// ```zig
/// const scheme = link.classify("https://example.com").?;
/// ```
pub fn classify(uri: []const u8) ?Scheme {
    if (uri.len == 0 or uri.len > max_uri_bytes or containsSeparator(uri)) {
        return null;
    }

    const parsed = std.Uri.parse(uri) catch return null;
    const scheme = supportedScheme(parsed.scheme) orelse return null;

    switch (scheme) {
        .http, .https => {
            if (parsed.host == null) {
                return null;
            }
        },
        .file => {
            const path = switch (parsed.path) {
                .raw, .percent_encoded => |value| value,
            };

            if (path.len == 0 or path[0] != '/') {
                return null;
            }
        },
    }

    return scheme;
}

/// Finds the supported URI containing `byte_offset` in one logical line.
/// Delimiters and unmatched closing punctuation are excluded from the match.
///
/// ```zig
/// const match = link.extractAt("see (https://example.com).", 10).?;
/// const uri = match.text("see (https://example.com).");
/// ```
pub fn extractAt(line: []const u8, byte_offset: usize) ?Match {
    if (line.len == 0 or byte_offset >= line.len) {
        return null;
    }

    const lower_bound = byte_offset -| (max_uri_bytes - 1);
    var index = byte_offset + 1;
    while (index > lower_bound) {
        index -= 1;

        const prefix = prefixAt(line, index) orelse continue;
        if (!validStart(line, index)) {
            continue;
        }

        const raw_end = tokenEnd(line, index);
        const end = trimEnd(line[index..raw_end]) + index;
        if (byte_offset >= end) {
            continue;
        }

        const uri = line[index..end];
        const scheme = classify(uri) orelse continue;
        if (scheme != prefix.scheme) {
            continue;
        }

        return .{ .scheme = scheme, .start = index, .end = end };
    }

    return null;
}

fn supportedScheme(value: []const u8) ?Scheme {
    if (std.ascii.eqlIgnoreCase(value, "file")) {
        return .file;
    }
    if (std.ascii.eqlIgnoreCase(value, "http")) {
        return .http;
    }
    if (std.ascii.eqlIgnoreCase(value, "https")) {
        return .https;
    }

    return null;
}

fn prefixAt(line: []const u8, index: usize) ?Prefix {
    for (prefixes) |prefix| {
        if (prefix.text.len <= line.len - index and
            std.ascii.startsWithIgnoreCase(line[index..], prefix.text))
        {
            return prefix;
        }
    }

    return null;
}

fn validStart(line: []const u8, index: usize) bool {
    if (index == 0) {
        return true;
    }

    const previous = line[index - 1];
    return !std.ascii.isAlphanumeric(previous) and previous != '_';
}

fn tokenEnd(line: []const u8, start: usize) usize {
    const limit = @min(line.len, start +| max_uri_bytes);
    var end = start;
    while (end < limit and !isSeparator(line[end])) : (end += 1) {}

    return end;
}

fn trimEnd(uri: []const u8) usize {
    var end = uri.len;
    var pairs = delimiterCounts(uri);
    while (end != 0) {
        switch (uri[end - 1]) {
            '.', ',', ';', ':', '!', '?' => end -= 1,
            ')' => {
                if (pairs.close_parentheses <= pairs.open_parentheses) {
                    break;
                }

                pairs.close_parentheses -= 1;
                end -= 1;
            },
            ']' => {
                if (pairs.close_brackets <= pairs.open_brackets) {
                    break;
                }

                pairs.close_brackets -= 1;
                end -= 1;
            },
            '}' => {
                if (pairs.close_braces <= pairs.open_braces) {
                    break;
                }

                pairs.close_braces -= 1;
                end -= 1;
            },
            else => break,
        }
    }

    return end;
}

const DelimiterCounts = struct {
    open_parentheses: usize = 0,
    close_parentheses: usize = 0,
    open_brackets: usize = 0,
    close_brackets: usize = 0,
    open_braces: usize = 0,
    close_braces: usize = 0,
};

fn delimiterCounts(uri: []const u8) DelimiterCounts {
    var counts: DelimiterCounts = .{};
    for (uri) |byte| {
        switch (byte) {
            '(' => counts.open_parentheses += 1,
            ')' => counts.close_parentheses += 1,
            '[' => counts.open_brackets += 1,
            ']' => counts.close_brackets += 1,
            '{' => counts.open_braces += 1,
            '}' => counts.close_braces += 1,
            else => {},
        }
    }

    return counts;
}

fn containsSeparator(uri: []const u8) bool {
    for (uri) |byte| {
        if (isSeparator(byte)) {
            return true;
        }
    }

    return false;
}

fn isSeparator(byte: u8) bool {
    if (std.ascii.isControl(byte) or std.ascii.isWhitespace(byte)) {
        return true;
    }

    return switch (byte) {
        '"', '\'', '<', '>', '`' => true,
        else => false,
    };
}

test "classification accepts supported structured URIs" {
    try std.testing.expectEqual(Scheme.http, classify("http://example.com").?);
    try std.testing.expectEqual(Scheme.https, classify("HTTPS://example.com/a?q=1#part").?);
    try std.testing.expectEqual(Scheme.file, classify("file:///tmp/a%20b.txt").?);
    try std.testing.expectEqual(Scheme.file, classify("file://localhost/tmp/a.txt").?);
}

test "classification rejects unsupported and malformed URIs" {
    try std.testing.expect(classify("ssh://example.com") == null);
    try std.testing.expect(classify("https://") == null);
    try std.testing.expect(classify("https://example.com/a b") == null);
    try std.testing.expect(classify("file://relative") == null);
    try std.testing.expect(classify("file:relative") == null);
    try std.testing.expect(classify("x" ** (max_uri_bytes + 1)) == null);
}

test "extraction returns the URI under every one of its bytes" {
    const line = "open (https://example.com/a_(b)?q=1#part), now";
    const expected = "https://example.com/a_(b)?q=1#part";
    const start = std.mem.indexOf(u8, line, expected).?;

    for (start..start + expected.len) |offset| {
        const match = extractAt(line, offset).?;
        try std.testing.expectEqual(Scheme.https, match.scheme);
        try std.testing.expectEqualStrings(expected, match.text(line));
    }
}

test "extraction trims prose delimiters and unmatched closing punctuation" {
    const cases = [_]struct {
        line: []const u8,
        expected: []const u8,
    }{
        .{ .line = "<http://example.com>.", .expected = "http://example.com" },
        .{ .line = "[file](file:///tmp/a%20b.txt)", .expected = "file:///tmp/a%20b.txt" },
        .{ .line = "url='https://example.com/path';", .expected = "https://example.com/path" },
    };

    for (cases) |case| {
        const start = std.mem.indexOf(u8, case.line, case.expected).?;
        const match = extractAt(case.line, start + case.expected.len / 2).?;
        try std.testing.expectEqualStrings(case.expected, match.text(case.line));
    }
}

test "extraction chooses the link containing the cursor" {
    const line = "http://one.example then file:///tmp/two";
    const second = "file:///tmp/two";
    const second_start = std.mem.indexOf(u8, line, second).?;

    const match = extractAt(line, second_start + 8).?;
    try std.testing.expectEqual(Scheme.file, match.scheme);
    try std.testing.expectEqualStrings(second, match.text(line));
    try std.testing.expect(extractAt(line, std.mem.indexOf(u8, line, "then").?) == null);
    try std.testing.expect(extractAt("abchttps://example.com", 10) == null);
}

test "trailing punctuation is not part of the link" {
    const line = "https://example.com/path.";
    const period = line.len - 1;

    try std.testing.expectEqualStrings(
        "https://example.com/path",
        extractAt(line, period - 1).?.text(line),
    );
    try std.testing.expect(extractAt(line, period) == null);
}
