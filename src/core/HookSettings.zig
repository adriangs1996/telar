//! Where `telar integration install` writes an agent's hooks, and the text
//! that marks telar's own entries there. The CLI writes the file; the
//! runtime reads it to know whether the hooks are installed.

const std = @import("std");
const AgentConfigRoot = @import("AgentConfigRoot.zig");
const HookSettings = @This();

root: AgentConfigRoot,
/// Whether the agent reads its hooks from the directory its variable
/// names; one that does not reads them under the home directory always.
follows_environment: bool = true,
file: []const u8,
/// The end of every command telar installs, `... hook <agent>`.
marker: []const u8,

pub const claude: HookSettings = .{
    .root = AgentConfigRoot.claude,
    .file = "settings.json",
    .marker = " hook claude",
};

pub const codex: HookSettings = .{
    .root = AgentConfigRoot.codex,
    .file = "hooks.json",
    .marker = " hook codex",
};

/// Cursor reads user hooks from the home directory whatever
/// `CURSOR_CONFIG_DIR` says.
pub const cursor: HookSettings = .{
    .root = AgentConfigRoot.cursor,
    .follows_environment = false,
    .file = "hooks.json",
    .marker = " hook cursor",
};

/// The variable whose value `directory` and `path` take as `override`.
///
/// ```zig
/// const override = if (settings.environment()) |name| environ.getPosix(name) else null;
/// ```
pub fn environment(self: HookSettings) ?[]const u8 {
    return if (self.follows_environment) self.root.environment else null;
}

/// The directory the agent reads its hooks from. Null without a home.
///
/// ```zig
/// const directory = HookSettings.codex.directory(codex_home, home, &buffer) orelse return;
/// ```
pub fn directory(self: HookSettings, override: ?[]const u8, home: ?[]const u8, buffer: []u8) ?[]const u8 {
    return self.root.resolve(if (self.follows_environment) override else null, home, buffer);
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

test "hooks live under the agent's variable when it reads them there, else under the home directory" {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("/srv/codex/hooks.json", codex.path("/srv/codex", "/home/me", &buffer).?);
    try std.testing.expectEqualStrings("/home/me/.codex/hooks.json", codex.path("", "/home/me", &buffer).?);
    try std.testing.expectEqualStrings("/srv/claude/settings.json", claude.path("/srv/claude", "/home/me", &buffer).?);
    try std.testing.expectEqualStrings("/home/me/.cursor/hooks.json", cursor.path("/srv/cursor", "/home/me", &buffer).?);
    try std.testing.expect(cursor.environment() == null);
    try std.testing.expect(cursor.path(null, null, &buffer) == null);
}
