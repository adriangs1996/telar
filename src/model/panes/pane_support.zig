//! One client-owned projection of a runtime pane. No presentation resources.

const std = @import("std");

/// Bytes a displayed directory name keeps; longer names are cut at a code point.
pub const max_cwd_name_bytes = 48;

pub fn displayCwdName(path: []const u8) []const u8 {
    if (path.len == 0) {
        return "";
    }

    const basename = cwdBaseName(path);
    if (!validCwdName(basename)) {
        return "";
    }

    var end = @min(basename.len, max_cwd_name_bytes);
    while (end < basename.len and end > 0 and basename[end] & 0b1100_0000 == 0b1000_0000) {
        end -= 1;
    }

    return basename[0..end];
}

fn cwdBaseName(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and isPathSeparator(path[end - 1])) {
        end -= 1;
    }

    const trimmed = path[0..end];
    if (trimmed.len == 1 and isPathSeparator(trimmed[0])) {
        return trimmed;
    }

    const separator = std.mem.lastIndexOfAny(u8, trimmed, "/\\") orelse return trimmed;
    const name = trimmed[separator + 1 ..];
    return if (name.len == 0) trimmed else name;
}

fn validCwdName(name: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(name)) {
        return false;
    }

    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return false;
        }
    }

    return true;
}

fn isPathSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}
