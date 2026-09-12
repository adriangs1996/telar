//! The executable an application bundle starts. Finder passes no arguments,
//! and `telar` without arguments is the terminal client, so the bundle names
//! this launcher instead: it execs `telar gui --login-shell`. The binary lives
//! under Resources because macOS file systems fold case and `Telar` and
//! `telar` cannot share `Contents/MacOS`.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buffer[0..try std.process.executableDirPath(init.io, &dir_buffer)];
    var telar_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const telar = try std.fmt.bufPrint(&telar_buffer, "{s}/../Resources/bin/telar", .{dir});

    // An absolute argv[0] is executed as a path, not searched on PATH.
    return std.process.replace(init.io, .{ .argv = &.{ telar, "gui", "--login-shell" } });
}
