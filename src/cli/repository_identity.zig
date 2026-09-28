//! The repository identity: the `origin` URL of a clone reduced to
//! `host/path`, so the clones of one project on two machines compare equal
//! whether they were cloned over SSH, HTTPS or the scp-like form. It finds a
//! clone; it never decides where work runs.

const std = @import("std");

const scheme_separator = "://";
const git_suffix = ".git";

/// Reduces a remote URL to `host/path`: the user, the port, a trailing
/// `.git` and slashes are dropped and the host is lowercased. A local path
/// or a `file://` URL names no project another machine can have.
///
/// ```zig
/// const identity = try repository_identity.normalize("git@github.com:o/telar.git", &buffer);
/// // "github.com/o/telar"
/// ```
pub fn normalize(url: []const u8, buffer: []u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    const location = try split(trimmed);
    const host = hostOf(location.authority);
    var path = std.mem.trim(u8, location.path, "/");
    if (std.mem.endsWith(u8, path, git_suffix)) {
        path = std.mem.trimEnd(u8, path[0 .. path.len - git_suffix.len], "/");
    }

    if (host.len == 0 or path.len == 0) {
        return error.UnsupportedOrigin;
    }

    if (host.len + 1 + path.len > buffer.len) {
        return error.OriginTooLong;
    }

    for (host, 0..) |byte, index| {
        buffer[index] = std.ascii.toLower(byte);
    }

    buffer[host.len] = '/';
    @memcpy(buffer[host.len + 1 ..][0..path.len], path);
    return buffer[0 .. host.len + 1 + path.len];
}

const Location = struct {
    authority: []const u8,
    path: []const u8,
};

/// `scheme://authority/path`, or the scp-like `authority:path`, which Git
/// reads only when no slash comes before the first colon.
fn split(url: []const u8) !Location {
    if (std.mem.indexOf(u8, url, scheme_separator)) |separator| {
        const scheme = url[0..separator];
        if (std.ascii.eqlIgnoreCase(scheme, "file")) {
            return error.UnsupportedOrigin;
        }

        const rest = url[separator + scheme_separator.len ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.UnsupportedOrigin;
        return .{
            .authority = rest[0..slash],
            .path = rest[slash..],
        };
    }

    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return error.UnsupportedOrigin;
    if (std.mem.indexOfScalar(u8, url[0..colon], '/') != null) {
        return error.UnsupportedOrigin;
    }

    return .{
        .authority = url[0..colon],
        .path = url[colon + 1 ..],
    };
}

/// The host of `user@host:port`, or of `[v6]:port`.
fn hostOf(authority: []const u8) []const u8 {
    const at = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |index| index + 1 else 0;
    const host = authority[at..];
    if (std.mem.startsWith(u8, host, "[")) {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return "";
        return host[1..close];
    }

    const colon = std.mem.indexOfScalar(u8, host, ':') orelse return host;
    return host[0..colon];
}

test "the clones of one project agree on their identity whatever the transport" {
    var buffer: [256]u8 = undefined;
    for ([_][]const u8{
        "git@github.com:adriangs1996/telar.git",
        "https://github.com/adriangs1996/telar",
        "https://token@GitHub.com/adriangs1996/telar.git/",
        "ssh://git@github.com:22/adriangs1996/telar.git",
        " git@github.com:/adriangs1996/telar\n",
    }) |url| {
        try std.testing.expectEqualStrings("github.com/adriangs1996/telar", try normalize(url, &buffer));
    }

    try std.testing.expectEqualStrings("fe80::1/r", try normalize("ssh://git@[fe80::1]:22/r.git", &buffer));
}

test "local origins name no project another machine can have" {
    var buffer: [256]u8 = undefined;
    for ([_][]const u8{ "/srv/git/telar.git", "./telar", "file:///srv/git/telar.git", "", "github.com", "https://github.com/" }) |url| {
        try std.testing.expectError(error.UnsupportedOrigin, normalize(url, &buffer));
    }

    var small: [8]u8 = undefined;
    try std.testing.expectError(error.OriginTooLong, normalize("git@github.com:o/telar.git", &small));
}
