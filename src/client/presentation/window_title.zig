//! Bounded window-title formatting and a synchronous host-title port.

const Tokens = @import("Tokens.zig");
const std = @import("std");

pub const max_title_bytes = 256;

/// Expands a bounded configuration template into printable, complete UTF-8.
/// Example: `const text = render(&buffer, "{tab} - telar", .{ .tab = "build" });`.
pub fn render(buffer: *[max_title_bytes]u8, template: []const u8, tokens: Tokens) []const u8 {
    var len: usize = 0;
    var index: usize = 0;
    while (index < template.len) {
        if (template[index] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, index, '}')) |close| {
                const name = template[index + 1 .. close];
                if (tokenValue(name, tokens)) |value| {
                    len = append(buffer, len, value);
                    index = close + 1;
                    continue;
                }
            }
        }

        len = append(buffer, len, template[index .. index + 1]);
        index += 1;
    }

    var end: usize = 0;
    var output_len: usize = 0;
    while (end < len) {
        const size = std.unicode.utf8ByteSequenceLength(buffer[end]) catch break;
        if (size > len - end) {
            break;
        }

        const codepoint = std.unicode.utf8Decode(buffer[end..][0..size]) catch break;
        if (codepoint >= 0x20 and !(codepoint >= 0x7f and codepoint <= 0x9f)) {
            std.mem.copyForwards(u8, buffer[output_len..][0..size], buffer[end..][0..size]);
            output_len += size;
        }

        end += size;
    }

    return buffer[0..output_len];
}

fn tokenValue(name: []const u8, tokens: Tokens) ?[]const u8 {
    if (std.mem.eql(u8, name, "workspace")) {
        return tokens.workspace;
    }
    if (std.mem.eql(u8, name, "tab")) {
        return tokens.tab;
    }
    if (std.mem.eql(u8, name, "pane_title")) {
        return tokens.pane_title;
    }
    if (std.mem.eql(u8, name, "hostname")) {
        return tokens.hostname;
    }
    return null;
}

/// Ends a rendered title with `suffix`, cutting the title at a character
/// boundary when both do not fit, so the suffix always shows.
/// Example: `const title = appendSuffix(&buffer, rendered.len, " — limit reached: x");`.
pub fn appendSuffix(buffer: *[max_title_bytes]u8, len: usize, suffix: []const u8) []const u8 {
    const kept_suffix = suffix[0..@min(suffix.len, buffer.len)];
    var kept = @min(len, buffer.len - kept_suffix.len);
    while (kept > 0 and kept < len and buffer[kept] & 0xc0 == 0x80) {
        kept -= 1;
    }

    @memcpy(buffer[kept..][0..kept_suffix.len], kept_suffix);
    return buffer[0 .. kept + kept_suffix.len];
}

fn append(buffer: *[max_title_bytes]u8, len: usize, value: []const u8) usize {
    const room = buffer.len - len;
    const count = @min(room, value.len);
    @memcpy(buffer[len .. len + count], value[0..count]);
    return len + count;
}
