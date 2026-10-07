//! Resolves configuration sources before a generation evaluates them.

const std = @import("std");

pub fn defaultPath(environ: std.process.Environ, buffer: []u8) ![]const u8 {
    return resolveDefaultPath(.{
        .development = environ.getPosix("TELAR_DEVELOPMENT_CONFIG"),
        .xdg_config_home = environ.getPosix("XDG_CONFIG_HOME"),
        .home = environ.getPosix("HOME"),
    }, buffer);
}

fn resolveDefaultPath(environment: Environment, buffer: []u8) ![]const u8 {
    if (environment.development) |path| {
        if (path.len != 0) {
            return std.fmt.bufPrint(buffer, "{s}", .{path});
        }
    }
    if (environment.xdg_config_home) |base| {
        if (base.len != 0) {
            return std.fmt.bufPrint(buffer, "{s}/telar/config.lua", .{base});
        }
    }

    const home_path = environment.home orelse return error.HomeDirectoryUnavailable;
    if (home_path.len == 0) {
        return error.HomeDirectoryUnavailable;
    }

    return std.fmt.bufPrint(buffer, "{s}/.config/telar/config.lua", .{home_path});
}

const Environment = struct {
    development: ?[]const u8,
    xdg_config_home: ?[]const u8,
    home: ?[]const u8,
};
