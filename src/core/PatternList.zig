const history_filter = @import("history_filter.zig");
const std = @import("std");
/// Bounded list of case-sensitive substring patterns from configuration.
const PatternList = @This();

storage: [history_filter.max_patterns][history_filter.max_pattern_bytes]u8 = undefined,
lens: [history_filter.max_patterns]u8 = .{0} ** history_filter.max_patterns,
count: u8 = 0,

/// Adds one pattern; empty, oversized or NUL-carrying patterns are
/// rejected so a list always holds usable matchers.
///
/// ```zig
/// try list.add("vault kv get");
/// ```
pub fn add(list: *PatternList, pattern: []const u8) !void {
    if (pattern.len == 0 or pattern.len > history_filter.max_pattern_bytes) {
        return error.InvalidFilterPattern;
    }
    if (std.mem.indexOfScalar(u8, pattern, 0) != null) {
        return error.InvalidFilterPattern;
    }
    if (list.count == history_filter.max_patterns) {
        return error.TooManyFilterPatterns;
    }

    @memcpy(list.storage[list.count][0..pattern.len], pattern);
    list.lens[list.count] = @intCast(pattern.len);
    list.count += 1;
}

pub fn at(list: *const PatternList, index: usize) []const u8 {
    return list.storage[index][0..list.lens[index]];
}

pub fn matches(list: *const PatternList, text: []const u8) bool {
    for (0..list.count) |index| {
        if (std.mem.indexOf(u8, text, list.at(index)) != null) {
            return true;
        }
    }

    return false;
}
