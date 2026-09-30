//! Where an agent keeps its configuration: `environment` overrides the
//! directory on this machine, `directory` is relative to the home. One
//! table for every reader: `telar machine setup` copies from it, `telar
//! integration` writes hooks into it and the runtime reads them there.

const std = @import("std");
const AgentConfigRoot = @This();

environment: ?[]const u8,
/// Appended to the environment variable's value, for XDG bases.
environment_suffix: []const u8 = "",
directory: []const u8,

pub const claude: AgentConfigRoot = .{
    .environment = "CLAUDE_CONFIG_DIR",
    .directory = ".claude",
};

pub const codex: AgentConfigRoot = .{
    .environment = "CODEX_HOME",
    .directory = ".codex",
};

pub const pi: AgentConfigRoot = .{
    .environment = "PI_CODING_AGENT_DIR",
    .directory = ".pi/agent",
};

pub const opencode: AgentConfigRoot = .{
    .environment = "XDG_CONFIG_HOME",
    .environment_suffix = "/opencode",
    .directory = ".config/opencode",
};

pub const cursor: AgentConfigRoot = .{
    .environment = "CURSOR_CONFIG_DIR",
    .directory = ".cursor",
};

/// The configuration directory: `override`, the value of `environment`,
/// with `environment_suffix` when it is set and not empty; else
/// `directory` under `home`. Null without either.
///
/// ```zig
/// const root = AgentConfigRoot.codex.resolve(codex_home, home, &buffer) orelse return;
/// ```
pub fn resolve(self: AgentConfigRoot, override: ?[]const u8, home: ?[]const u8, buffer: []u8) ?[]const u8 {
    if (override) |value| {
        if (value.len != 0) {
            return std.fmt.bufPrint(buffer, "{s}{s}", .{ value, self.environment_suffix }) catch null;
        }
    }

    const base = home orelse return null;
    if (base.len == 0) {
        return null;
    }

    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ base, self.directory }) catch null;
}

test "a configuration root follows its variable, else the home directory" {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("/srv/codex", codex.resolve("/srv/codex", "/home/me", &buffer).?);
    try std.testing.expectEqualStrings("/home/me/.codex", codex.resolve("", "/home/me", &buffer).?);
    try std.testing.expectEqualStrings("/xdg/opencode", opencode.resolve("/xdg", "/home/me", &buffer).?);
    try std.testing.expectEqualStrings("/home/me/.pi/agent", pi.resolve(null, "/home/me", &buffer).?);
    try std.testing.expect(cursor.resolve(null, null, &buffer) == null);
}
