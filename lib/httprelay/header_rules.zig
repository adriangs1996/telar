//! HTTP header rules the relays share: when a response body is observable
//! SSE.

const std = @import("std");

/// Recognizes the SSE media type while allowing parameters and ASCII case.
///
/// ```zig
/// const streaming = isEventStreamContentType("text/event-stream; charset=utf-8");
/// ```
pub fn isEventStreamContentType(value: []const u8) bool {
    const parameters = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(
        std.mem.trim(u8, value[0..parameters], " \t"),
        "text/event-stream",
    );
}

/// Returns whether a present Content-Encoding value leaves bytes unchanged.
///
/// ```zig
/// const unchanged = isIdentityContentEncoding("identity");
/// ```
pub fn isIdentityContentEncoding(value: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    var found = false;

    while (tokens.next()) |token| {
        const coding = std.mem.trim(u8, token, " \t");

        if (coding.len == 0 or !std.ascii.eqlIgnoreCase(coding, "identity")) {
            return false;
        }

        found = true;
    }

    return found;
}

test "event-stream types allow parameters and case, identity allows only identity" {
    try std.testing.expect(isEventStreamContentType("Text/Event-Stream; charset=utf-8"));
    try std.testing.expect(!isEventStreamContentType("application/json"));
    try std.testing.expect(isIdentityContentEncoding("identity"));
    try std.testing.expect(isIdentityContentEncoding("identity, IDENTITY"));
    try std.testing.expect(!isIdentityContentEncoding("gzip"));
    try std.testing.expect(!isIdentityContentEncoding("identity, gzip"));
    try std.testing.expect(!isIdentityContentEncoding(""));
}
