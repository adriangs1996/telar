//! Where an account's telar settings live: `$XDG_CONFIG_HOME/telar`, or
//! `~/.config/telar` when it is unset or empty.
const std = @import("std");

/// Resolves `file_name` inside the settings directory into `buffer`. The
/// returned slice is valid while the buffer is.
///
/// ```zig
/// const machines = try config_directory.path(environ, "machines.json", &buffer);
/// ```
pub fn path(environ: std.process.Environ, file_name: []const u8, buffer: []u8) ![]const u8 {
    if (environ.getPosix("XDG_CONFIG_HOME")) |base| {
        if (base.len != 0) {
            return std.fmt.bufPrint(buffer, "{s}/telar/{s}", .{ base, file_name });
        }
    }

    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    if (home.len == 0) {
        return error.HomeDirectoryUnavailable;
    }

    return std.fmt.bufPrint(buffer, "{s}/.config/telar/{s}", .{ home, file_name });
}
