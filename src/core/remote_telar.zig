//! How a machine's telar is named in a remote command line: the absolute
//! path `telar machine setup` installed it at, or `telar` looked up on the
//! PATH of non-interactive SSH sessions when a profile has none. The path is
//! written unquoted into commands that sh, bash, zsh or fish parse, so it
//! may only hold characters none of them reads specially.
const std = @import("std");

/// The longest path a machine profile stores, in bytes.
pub const max_path_bytes = 255;

/// What a remote command runs when the profile names no path.
pub const default_program = "telar";

/// Refuses a path a remote shell could split, expand or quote differently:
/// it is absolute, and holds only ASCII letters, digits and `/._+-`.
///
/// ```zig
/// try remote_telar.validate("/home/dev/.local/share/telar/0.3.0/telar");
/// ```
pub fn validate(path: []const u8) !void {
    if (path.len < 2 or path.len > max_path_bytes or path[0] != '/') {
        return error.InvalidRemoteTelarPath;
    }

    for (path) |byte| {
        const allowed = std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '.' or byte == '_' or byte == '+' or byte == '-';
        if (!allowed) {
            return error.InvalidRemoteTelarPath;
        }
    }

    if (std.mem.indexOf(u8, path, "/../") != null or std.mem.endsWith(u8, path, "/..") or path[path.len - 1] == '/') {
        return error.InvalidRemoteTelarPath;
    }
}

/// The program a remote command runs: the saved path, or `telar`.
///
/// ```zig
/// const program = remote_telar.program(profile.telarPath());
/// ```
pub fn program(path: ?[]const u8) []const u8 {
    return path orelse default_program;
}

test "remote telar paths hold only shell-inert characters" {
    try validate("/home/dev/.local/share/telar/0.3.0/telar");
    try validate("/home/dev/.local/share/telar/0.0.0-0123456789ab/telar");

    for ([_][]const u8{
        "",
        "/",
        "telar",
        "~/bin/telar",
        "/home/dev user/telar",
        "/home/dev/$(id)/telar",
        "/home/dev/it's/telar",
        "/home/dev/a;b",
        "/home/dev/a\\b",
        "/home/dev/../root/telar",
        "/home/dev/telar/",
        "/home/dev/\x00telar",
        "/" ++ "a" ** max_path_bytes,
    }) |path| {
        try std.testing.expectError(error.InvalidRemoteTelarPath, validate(path));
    }
}

test "a profile without a path runs telar from the PATH" {
    try std.testing.expectEqualStrings("telar", program(null));
    try std.testing.expectEqualStrings("/opt/telar", program("/opt/telar"));
}
