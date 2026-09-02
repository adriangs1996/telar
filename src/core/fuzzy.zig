//! Case-insensitive subsequence scoring shared by the client's goto picker
//! and the runtime's fuzzy history matching, so both sides rank identically.

const std = @import("std");

/// Null when the needle is not a subsequence of the haystack. Earlier and
/// tighter matches score higher; an empty needle matches everything with the
/// lowest positive score.
///
/// ```zig
/// const rank = score("zig build test", "zbt") orelse return;
/// ```
pub fn score(haystack: []const u8, needle: []const u8) ?u32 {
    if (needle.len == 0) {
        return 1;
    }
    if (needle.len > haystack.len) {
        return null;
    }

    var first: ?usize = null;
    var last: usize = 0;
    var needle_index: usize = 0;
    for (haystack, 0..) |byte, index| {
        if (needle_index == needle.len) {
            break;
        }
        if (std.ascii.toLower(byte) != std.ascii.toLower(needle[needle_index])) {
            continue;
        }

        if (first == null) {
            first = index;
        }
        last = index;
        needle_index += 1;
    }
    if (needle_index != needle.len) {
        return null;
    }

    const start = first.?;
    const span = last - start + 1;
    const base: u32 = 4096;
    return base -| @as(u32, @intCast(start * 8)) -| @as(u32, @intCast((span - needle.len) * 16));
}

test "scores prefer earlier and tighter subsequence matches" {
    try std.testing.expect(score("telar", "") != null);
    try std.testing.expect(score("Telar", "tel").? > score("proxy-telar", "tel").?);
    try std.testing.expect(score("telar", "tel").? > score("t-e-l", "tel").?);
    try std.testing.expect(score("telar", "xyz") == null);
    try std.testing.expect(score("ab", "abc") == null);
}
