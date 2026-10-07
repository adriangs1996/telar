//! Pure recognition of supported URI text. Terminal coordinates, OSC 8
//! metadata and opener policy belong to the process-specific adapters.

const Prefix = @import("Prefix.zig");
const std = @import("std");
const Match = @import("Match.zig");

pub const max_uri_bytes = 4096;

pub const Scheme = enum {
    file,
    http,
    https,
    external,
    /// A local path found in prose by `pathAt`; never a URI, so `classify`
    /// never returns it.
    path,
};

const prefixes = [_]Prefix{
    .{ .text = "https://", .scheme = .https },
    .{ .text = "http://", .scheme = .http },
    .{ .text = "file://", .scheme = .file },
    .{ .text = "mailto:", .scheme = .external },
    .{ .text = "ftp://", .scheme = .external },
    .{ .text = "ssh:", .scheme = .external },
    .{ .text = "git://", .scheme = .external },
    .{ .text = "tel:", .scheme = .external },
    .{ .text = "magnet:", .scheme = .external },
    .{ .text = "ipfs://", .scheme = .external },
    .{ .text = "ipns://", .scheme = .external },
    .{ .text = "gemini://", .scheme = .external },
    .{ .text = "gopher://", .scheme = .external },
    .{ .text = "news:", .scheme = .external },
};

/// Classifies one complete supported URI after validating its structure.
///
/// ```zig
/// const scheme = urlscan.classify("https://example.com").?;
/// ```
pub fn classify(uri: []const u8) ?Scheme {
    if (uri.len == 0 or uri.len > max_uri_bytes or containsSeparator(uri) or !std.unicode.utf8ValidateSlice(uri)) {
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
        .path => return null,
        .external => {
            if (uri.len <= parsed.scheme.len + 1) {
                return null;
            }

            if (std.mem.startsWith(u8, uri[parsed.scheme.len + 1 ..], "//") and parsed.host == null) {
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
/// const match = urlscan.extractAt("see (https://example.com).", 10).?;
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
        if (raw_end < line.len and !isSeparator(line[raw_end])) {
            continue;
        }

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

    const external = [_][]const u8{ "mailto", "ftp", "ssh", "git", "tel", "magnet", "ipfs", "ipns", "gemini", "gopher", "news" };
    for (external) |scheme| {
        if (std.ascii.eqlIgnoreCase(value, scheme)) {
            return .external;
        }
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
    const limit = @min(line.len, start +| (max_uri_bytes + 1));
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

/// A byte that ends a URI token: controls, whitespace and quoting punctuation.
/// Example: `if (uri.isSeparator(line[end])) break;`
pub fn isSeparator(byte: u8) bool {
    if (std.ascii.isControl(byte) or std.ascii.isWhitespace(byte)) {
        return true;
    }

    return switch (byte) {
        '"', '\'', '<', '>', '`' => true,
        else => false,
    };
}

const DelimiterCounts = struct {
    open_parentheses: usize = 0,
    close_parentheses: usize = 0,
    open_brackets: usize = 0,
    close_brackets: usize = 0,
    open_braces: usize = 0,
    close_braces: usize = 0,
};
