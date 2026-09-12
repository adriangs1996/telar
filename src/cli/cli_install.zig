//! A bundled Telar is invisible to shells and agents until `telar` is on the
//! PATH. These commands manage one symlink to the running executable, the
//! way Ghostty and VS Code install their command-line tools.

const std = @import("std");
const CliOptions = @import("arguments/CliOptions.zig");

const default_dir = "/usr/local/bin";

/// ```zig
/// try cli_install.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: CliOptions) !void {
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = if (options.dir) |value| std.mem.span(value) else default_dir;
    const link = try std.fmt.bufPrint(&link_buffer, "{s}/telar", .{dir});
    var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const target = target_buffer[0..try std.process.executablePath(init.io, &target_buffer)];

    switch (options.action) {
        .status => {
            var current_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const current = readLink(init.io, link, &current_buffer) catch |err| switch (err) {
                error.FileNotFound => {
                    try print(init.io, "telar cli: {s} is not installed\n", .{link});
                    return;
                },
                else => |other| return other,
            };
            try print(init.io, "telar cli: {s} -> {s}\n", .{ link, current });
        },
        .install => {
            try removeLink(init.io, link);
            std.Io.Dir.cwd().symLink(init.io, target, link, .{}) catch |err| switch (err) {
                error.AccessDenied, error.PermissionDenied => {
                    std.debug.print("telar cli: cannot write {s}; rerun with sudo or pass --dir ~/.local/bin\n", .{link});
                    return err;
                },
                else => |other| return other,
            };
            try print(init.io, "telar cli: installed {s} -> {s}\n", .{ link, target });
        },
        .uninstall => {
            try removeLink(init.io, link);
            try print(init.io, "telar cli: removed {s}\n", .{link});
        },
    }
}

fn readLink(io: std.Io, link: []const u8, buffer: []u8) ![]const u8 {
    const len = try std.Io.Dir.cwd().readLink(io, link, buffer);
    return buffer[0..len];
}

/// Removes an existing symlink at `link`. Anything else there is left alone
/// and reported, because it is not ours to replace.
fn removeLink(io: std.Io, link: []const u8) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    _ = readLink(io, link, &buffer) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotLink => {
            std.debug.print("telar cli: {s} exists and is not a symlink; refusing to replace it\n", .{link});
            return error.NotLink;
        },
        else => |other| return other,
    };
    try std.Io.Dir.cwd().deleteFile(io, link);
}

fn print(io: std.Io, comptime format: []const u8, args: anytype) !void {
    var buffer: [2 * std.fs.max_path_bytes + 64]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.bufPrint(&buffer, format, args));
}
