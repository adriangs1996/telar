//! What `telar machine setup` may copy of an agent's configuration, and
//! what it never copies (docs/plans/machine-setup.md, "What is synced").
//! The sync reads nothing outside these lists: each agent names the files
//! and directories of its configuration directory that hold settings,
//! instructions, skills and commands. Credentials, sessions, history,
//! caches and databases are not in any list, and the denylist refuses a
//! credential by name or by where a symlink leads even inside one.
//! Sources for each path are in the plan's "Agent facts".
const std = @import("std");
const values = @import("arguments/values.zig");
const ConfigEntry = @import("ConfigEntry.zig");
const ConfigRoot = @import("ConfigRoot.zig");

pub const Agent = values.HookAgent;

pub fn rootFor(agent: Agent) ConfigRoot {
    return switch (agent) {
        .claude => .{ .environment = "CLAUDE_CONFIG_DIR", .directory = ".claude" },
        .codex => .{ .environment = "CODEX_HOME", .directory = ".codex" },
        .pi => .{ .environment = "PI_CODING_AGENT_DIR", .directory = ".pi/agent" },
        .opencode => .{ .environment = "XDG_CONFIG_HOME", .environment_suffix = "/opencode", .directory = ".config/opencode" },
        .cursor => .{ .environment = "CURSOR_CONFIG_DIR", .directory = ".cursor" },
    };
}

pub fn entriesFor(agent: Agent) []const ConfigEntry {
    return switch (agent) {
        .claude => &.{
            .{ .path = "settings.json", .kind = .file, .format = .json, .hooks = true },
            .{ .path = "CLAUDE.md", .kind = .file },
            .{ .path = "keybindings.json", .kind = .file, .format = .json },
            .{ .path = "rules", .kind = .directory },
            .{ .path = "skills", .kind = .directory },
            .{ .path = "commands", .kind = .directory },
            .{ .path = "agents", .kind = .directory },
            .{ .path = "output-styles", .kind = .directory },
            .{ .path = "themes", .kind = .directory },
        },
        .codex => &.{
            .{ .path = "config.toml", .kind = .file, .format = .toml },
            .{ .path = "hooks.json", .kind = .file, .format = .json, .hooks = true },
            .{ .path = "AGENTS.md", .kind = .file },
            .{ .path = "AGENTS.override.md", .kind = .file },
            .{ .path = "rules", .kind = .directory },
            .{ .path = "prompts", .kind = .directory },
        },
        .pi => &.{
            .{ .path = "settings.json", .kind = .file, .format = .json },
            .{ .path = "keybindings.json", .kind = .file, .format = .json },
            .{ .path = "AGENTS.md", .kind = .file },
            .{ .path = "SYSTEM.md", .kind = .file },
            .{ .path = "APPEND_SYSTEM.md", .kind = .file },
            .{ .path = "skills", .kind = .directory },
            .{ .path = "prompts", .kind = .directory },
            .{ .path = "themes", .kind = .directory },
            .{ .path = "extensions", .kind = .directory },
        },
        .opencode => &.{
            .{ .path = "opencode.json", .kind = .file, .format = .json },
            .{ .path = "opencode.jsonc", .kind = .file, .format = .json },
            .{ .path = "tui.json", .kind = .file, .format = .json },
            .{ .path = "AGENTS.md", .kind = .file },
            .{ .path = "agents", .kind = .directory },
            .{ .path = "commands", .kind = .directory },
            .{ .path = "modes", .kind = .directory },
            .{ .path = "skills", .kind = .directory },
            .{ .path = "themes", .kind = .directory },
            .{ .path = "plugins", .kind = .directory },
        },
        .cursor => &.{
            .{ .path = "cli-config.json", .kind = .file, .format = .json },
            .{ .path = "hooks.json", .kind = .file, .format = .json, .hooks = true },
            .{ .path = "skills", .kind = .directory },
            .{ .path = "agents", .kind = .directory },
        },
    };
}

/// Skills every agent but Claude Code also reads, relative to the home.
pub const shared_skills = ".agents/skills";

/// Directories the machine accepts synced files under, relative to its
/// home. `receive-config` refuses any other path.
pub const accepted_roots = [_][]const u8{
    ".claude/",
    ".codex/",
    ".pi/agent/",
    ".config/opencode/",
    ".cursor/",
    ".agents/skills/",
};

/// What telar itself writes there through `integration install`; syncing
/// this machine's copy would undo the machine's.
const telar_owned = [_][]const u8{
    "skills/telar-coordinator",
    "extensions/telar.ts",
    "plugins/telar.ts",
};

/// File names that hold credentials, wherever they appear.
const credential_names = [_][]const u8{
    ".credentials.json",
    "auth.json",
    "mcp-auth.json",
    "credentials.json",
    "credentials",
    ".netrc",
    ".npmrc",
    ".pypirc",
    ".git-credentials",
    "models.json",
};

/// Extensions of key and certificate files.
const credential_extensions = [_][]const u8{ ".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db" };

/// Directories no synced path may lead into, even through a symlink.
const credential_directories = [_][]const u8{
    ".ssh",
    ".gnupg",
    ".aws",
    ".kube",
    ".docker",
    "Keychains",
    "gcloud",
    ".password-store",
};

/// Whether a path, here or where a symlink leads, may never leave this
/// machine: a credential file by name, a key by extension, anything under a
/// credential directory, an `.env` file or an SSH key.
///
/// ```zig
/// if (config_allowlist.denied("/home/dev/.codex/auth.json")) continue;
/// ```
pub fn denied(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        for (credential_directories) |directory| {
            if (std.mem.eql(u8, component, directory)) {
                return true;
            }
        }
    }

    const name = std.fs.path.basename(path);
    for (credential_names) |credential| {
        if (std.mem.eql(u8, name, credential)) {
            return true;
        }
    }

    for (credential_extensions) |extension| {
        if (std.ascii.endsWithIgnoreCase(name, extension)) {
            return true;
        }
    }

    return std.mem.eql(u8, name, ".env") or std.mem.startsWith(u8, name, ".env.") or
        std.mem.startsWith(u8, name, "id_rsa") or std.mem.startsWith(u8, name, "id_ed25519") or
        std.mem.startsWith(u8, name, "id_ecdsa") or std.mem.startsWith(u8, name, "id_dsa");
}

/// Whether `relative`, a path under an agent's directory, is a file telar's
/// integration writes there.
pub fn telarOwned(relative: []const u8) bool {
    for (telar_owned) |owned| {
        if (std.mem.eql(u8, relative, owned) or (std.mem.startsWith(u8, relative, owned) and relative[owned.len] == '/')) {
            return true;
        }
    }

    return false;
}

/// Whether the machine may write `relative`, a path under its home: it lies
/// under an accepted root, has no empty, `.` or `..` component, no hidden
/// component below the root, no control byte, and is not denied.
///
/// ```zig
/// if (!config_allowlist.acceptable(".claude/settings.json")) return error.RefusedPath;
/// ```
pub fn acceptable(relative: []const u8) bool {
    if (relative.len == 0 or relative.len > std.fs.max_path_bytes or relative[0] == '/' or denied(relative)) {
        return false;
    }

    for (relative) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '\\') {
            return false;
        }
    }

    for (accepted_roots) |root| {
        if (!std.mem.startsWith(u8, relative, root) or relative.len == root.len) {
            continue;
        }

        var components = std.mem.splitScalar(u8, relative[root.len..], '/');
        while (components.next()) |component| {
            if (component.len == 0 or component[0] == '.') {
                return false;
            }
        }

        return true;
    }

    return false;
}

test "every known credential file is denied" {
    const credentials = [_][]const u8{
        "/Users/a/.claude/.credentials.json",
        "/Users/a/.codex/auth.json",
        "/Users/a/.codex/.credentials.json",
        "/Users/a/.pi/agent/auth.json",
        "/Users/a/.pi/agent/models.json",
        "/Users/a/.local/share/opencode/auth.json",
        "/Users/a/.local/share/opencode/mcp-auth.json",
        "/Users/a/.config/cursor/auth.json",
        "/Users/a/.ssh/id_ed25519",
        "/Users/a/.ssh/config",
        "/Users/a/.aws/credentials",
        "/Users/a/.netrc",
        "/Users/a/.npmrc",
        "/Users/a/Library/Keychains/login.keychain-db",
        "/Users/a/.claude/skills/deploy/.env",
        "/Users/a/.claude/skills/deploy/.env.production",
        "/Users/a/.claude/skills/deploy/server.pem",
        "/Users/a/.config/gcloud/application_default_credentials.json",
    };

    for (credentials) |path| {
        try std.testing.expect(denied(path));
    }

    try std.testing.expect(!denied("/Users/a/.claude/settings.json"));
    try std.testing.expect(!denied("/Users/a/.claude/skills/deploy/SKILL.md"));
}

test "no allowlisted path names a credential file" {
    for (std.enums.values(Agent)) |agent| {
        for (entriesFor(agent)) |entry| {
            try std.testing.expect(!denied(entry.path));
        }
    }
}

test "the machine accepts only paths under the agents' directories" {
    try std.testing.expect(acceptable(".claude/settings.json"));
    try std.testing.expect(acceptable(".claude/skills/grill/SKILL.md"));
    try std.testing.expect(acceptable(".config/opencode/opencode.jsonc"));
    try std.testing.expect(acceptable(".agents/skills/x/SKILL.md"));

    for ([_][]const u8{
        "",
        ".claude/",
        "/etc/passwd",
        ".bashrc",
        ".ssh/authorized_keys",
        ".claude/../.ssh/authorized_keys",
        ".claude/skills/../../.ssh/authorized_keys",
        ".claude//settings.json",
        ".claude/skills/x/.git/config",
        ".claude/.credentials.json",
        ".codex/auth.json",
        ".claude.json",
        ".claude/skills/x\x1b[2J",
        ".local/share/opencode/auth.json",
    }) |path| {
        try std.testing.expect(!acceptable(path));
    }
}

test "telar's own integration files stay with the machine" {
    try std.testing.expect(telarOwned("skills/telar-coordinator"));
    try std.testing.expect(telarOwned("skills/telar-coordinator/SKILL.md"));
    try std.testing.expect(telarOwned("plugins/telar.ts"));
    try std.testing.expect(!telarOwned("skills/telar-coordinator-extra/SKILL.md"));
    try std.testing.expect(!telarOwned("skills/grill/SKILL.md"));
}
