//! Whether telar's hooks are installed for an agent, read from the settings
//! file `telar integration install` writes. Runs in an observation worker,
//! once per identified process: one bounded read and no allocation.

const std = @import("std");
const HookSettings = @import("providers/HookSettings.zig");

/// Bytes of the settings file searched for telar's entries; hook files are
/// far smaller.
const max_settings_bytes = 32 * 1024;

/// Reports whether the settings file holds a telar hook entry. `override`
/// is the value of the agent's directory variable, `home` the home
/// directory's.
///
/// ```zig
/// const on = hook_integration.installed(settings, codex_home, home);
/// ```
pub fn installed(settings: HookSettings, override: ?[]const u8, home: ?[]const u8) bool {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = settingsPath(settings, override, home, &path_buffer) orelse return false;
    const flags: std.posix.O = .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NONBLOCK = true,
    };
    const file = std.posix.openat(std.posix.AT.FDCWD, path, flags, 0) catch return false;
    defer _ = std.posix.system.close(file);

    var content: [max_settings_bytes]u8 = undefined;
    const len = std.posix.read(file, &content) catch return false;
    return std.mem.indexOf(u8, content[0..len], settings.marker) != null;
}

fn settingsPath(settings: HookSettings, override: ?[]const u8, home_directory: ?[]const u8, buffer: []u8) ?[]const u8 {
    if (override) |directory| {
        if (directory.len != 0) {
            return std.fmt.bufPrint(buffer, "{s}/{s}", .{ directory, settings.file }) catch null;
        }
    }

    const home = home_directory orelse return null;
    if (home.len == 0) {
        return null;
    }

    return std.fmt.bufPrint(buffer, "{s}/{s}/{s}", .{ home, settings.home_directory, settings.file }) catch null;
}

test "telar's entry in the settings file marks the hooks installed" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    const settings: HookSettings = .{
        .environment = "CODEX_HOME",
        .home_directory = ".codex",
        .file = "hooks.json",
        .marker = " hook codex",
    };

    try std.testing.expect(!installed(settings, directory, null));

    try temp.dir.writeFile(io, .{
        .sub_path = "hooks.json",
        .data = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"exec '/bin/other' notify\"}]}]}}",
    });
    try std.testing.expect(!installed(settings, directory, null));

    try temp.dir.writeFile(io, .{
        .sub_path = "hooks.json",
        .data = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"exec '/usr/bin/telar' hook codex\"}]}]}}",
    });
    try std.testing.expect(installed(settings, directory, null));
    try std.testing.expect(!installed(settings, null, null));
}
