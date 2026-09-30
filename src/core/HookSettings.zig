//! Where `telar integration install` writes an agent's hooks, and the text
//! that marks telar's own entries there. The CLI writes the file; the
//! runtime reads it to know whether the hooks are installed.

const std = @import("std");
const HookSettings = @This();

/// Variable that names the agent's configuration directory, when the agent
/// honours one.
environment: ?[]const u8 = null,
/// The configuration directory under the home directory otherwise.
home_directory: []const u8,
file: []const u8,
/// The end of every command telar installs, `... hook <agent>`.
marker: []const u8,

pub const claude: HookSettings = .{
    .home_directory = ".claude",
    .file = "settings.json",
    .marker = " hook claude",
};

pub const codex: HookSettings = .{
    .environment = "CODEX_HOME",
    .home_directory = ".codex",
    .file = "hooks.json",
    .marker = " hook codex",
};

/// Cursor reads user hooks from the home directory whatever
/// `CURSOR_CONFIG_DIR` says.
pub const cursor: HookSettings = .{
    .home_directory = ".cursor",
    .file = "hooks.json",
    .marker = " hook cursor",
};

/// The agent's configuration directory: the value of `environment` when it
/// is set, else `home_directory` under `home`. Null without either.
///
/// ```zig
/// const directory = HookSettings.codex.directory(codex_home, home, &buffer) orelse return;
/// ```
pub fn directory(self: HookSettings, override: ?[]const u8, home: ?[]const u8, buffer: []u8) ?[]const u8 {
    if (self.environment != null) {
        if (override) |value| {
            if (value.len != 0) {
                return std.fmt.bufPrint(buffer, "{s}", .{value}) catch null;
            }
        }
    }

    const base = home orelse return null;
    if (base.len == 0) {
        return null;
    }

    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ base, self.home_directory }) catch null;
}

/// The settings file inside `directory`.
///
/// ```zig
/// const path = HookSettings.codex.path(codex_home, home, &buffer) orelse return;
/// ```
pub fn path(self: HookSettings, override: ?[]const u8, home: ?[]const u8, buffer: []u8) ?[]const u8 {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = self.directory(override, home, &directory_buffer) orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ base, self.file }) catch null;
}

test "settings live under the agent's variable, else under the home directory" {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("/srv/codex/hooks.json", codex.path("/srv/codex", "/home/me", &buffer).?);
    try std.testing.expectEqualStrings("/home/me/.codex/hooks.json", codex.path("", "/home/me", &buffer).?);
    try std.testing.expectEqualStrings("/home/me/.codex", codex.directory(null, "/home/me", &buffer).?);
    try std.testing.expectEqualStrings("/home/me/.claude/settings.json", claude.path("/ignored", "/home/me", &buffer).?);
    try std.testing.expect(cursor.path(null, null, &buffer) == null);
}
