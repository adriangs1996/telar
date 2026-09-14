//! The client's home directory, copied once so paths in the chrome can be
//! shortened to `~` without touching the environment on the paint path.
const std = @import("std");
const HomePrefix = @This();

bytes: [1024]u8 = undefined,
len: u16 = 0,

/// Copies a home path; an oversized or empty path disables abbreviation.
/// Example: `chrome.home.set(environ.getPosix("HOME") orelse "");`
pub fn set(home: *HomePrefix, path: []const u8) void {
    if (path.len == 0 or path.len > home.bytes.len) {
        home.len = 0;
        return;
    }

    @memcpy(home.bytes[0..path.len], path);
    home.len = @intCast(path.len);
}

pub fn slice(home: *const HomePrefix) []const u8 {
    return home.bytes[0..home.len];
}

/// Writes `path` into `buffer` with the home prefix replaced by `~`.
/// Example: `const shown = HomePrefix.abbreviate(&buffer, "/Users/me/src", "/Users/me");`
pub fn abbreviate(buffer: []u8, path: []const u8, home: []const u8) []const u8 {
    const under_home = home.len != 0 and std.mem.startsWith(u8, path, home) and (path.len == home.len or path[home.len] == '/');
    if (!under_home) {
        const len = @min(path.len, buffer.len);
        @memcpy(buffer[0..len], path[0..len]);
        return buffer[0..len];
    }

    const tail = path[home.len..];
    const len = @min(tail.len, buffer.len -| 1);
    buffer[0] = '~';
    @memcpy(buffer[1 .. 1 + len], tail[0..len]);
    return buffer[0 .. 1 + len];
}

test "home abbreviation replaces only a whole leading component" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("~/sandbox/telar", abbreviate(&buffer, "/Users/me/sandbox/telar", "/Users/me"));
    try std.testing.expectEqualStrings("~", abbreviate(&buffer, "/Users/me", "/Users/me"));
    try std.testing.expectEqualStrings("/Users/meow", abbreviate(&buffer, "/Users/meow", "/Users/me"));
    try std.testing.expectEqualStrings("/srv/app", abbreviate(&buffer, "/srv/app", ""));
    var prefix: HomePrefix = .{};
    prefix.set("/Users/me");
    try std.testing.expectEqualStrings("/Users/me", prefix.slice());
    prefix.set("");
    try std.testing.expectEqual(@as(u16, 0), prefix.len);
}
