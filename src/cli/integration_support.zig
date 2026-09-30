//! `telar integration install|uninstall|status <agent>`: registers telar's
//! lifecycle reporting with an agent so its official events reach the
//! runtime. Claude Code, Codex and Cursor Agent get a command hook in their
//! settings files; Pi and OpenCode load a Telar source file from their
//! global extension or plugin directory.

const core = @import("telar-core");
const std = @import("std");
const IntegrationOptions = @import("arguments/IntegrationOptions.zig");
const values = @import("arguments/values.zig");
const Integration = @import("Integration.zig");
const TempFile = @import("TempFile.zig");
const HookSet = @import("HookSet.zig");
const skill = @import("skill.zig");

const max_settings_bytes = 4 * 1024 * 1024;
const max_extension_bytes = 64 * 1024;

/// `CwdChanged` reports a move into or out of a worktree when it happens,
/// not at the next tool call.
pub const claude_events = [_][]const u8{ "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification", "SessionEnd", "CwdChanged" };
pub const codex_events = [_][]const u8{ "SessionStart", "UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse", "Stop", "Interrupt", "SubagentStop", "SessionEnd" };
/// Cursor Agent fires no hook for approvals or plan reviews; the screen
/// reports those.
pub const cursor_events = [_][]const u8{ "sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "stop", "sessionEnd" };
/// Claude Code asks these hooks to create and remove its worktrees, so they
/// run in every session and answer with a path, never through the pane guard.
pub const claude_worktree_events = [_][]const u8{ "WorktreeCreate", "WorktreeRemove" };
/// Worktree hooks run `git worktree add`, which may take a while.
pub const worktree_timeout_seconds = 60;
/// The coordinator skill, installed next to an agent's settings so the agent
/// finds it among its own skills.
pub const coordinator_skill_directory = "skills/telar-coordinator";
pub const coordinator_skill_header =
    \\---
    \\name: telar-coordinator
    \\description: Delegate tasks to agents in their own Git worktrees and steer them through telar. Use when the user asks to implement, fix or build something in a separate worktree, or asks about, stops, redirects or reviews agents working in worktrees.
    \\---
    \\
    \\
;
const claude_marker = core.HookSettings.claude.marker;
const codex_marker = core.HookSettings.codex.marker;
const cursor_marker = core.HookSettings.cursor.marker;
/// The only `hooks.json` schema Cursor Agent documents.
const cursor_hooks_version = 1;

/// First line of the extension Telar writes for Pi and of the plugin it
/// writes for OpenCode; uninstall touches only files that start with it.
pub const pi_marker = "// telar-integration: pi";
pub const opencode_marker = "// telar-integration: opencode";
pub const pi_extension_template = @embedFile("integration/pi.ts");
pub const opencode_plugin_template = @embedFile("integration/opencode.ts");
const executable_placeholder = "\"__TELAR_EXECUTABLE__\"";

/// A Telar source file an agent loads through its own extension API
/// instead of hooks in a settings file.
const Extension = struct {
    agent: []const u8,
    /// What the agent calls such a file: `extension` or `plugin`.
    noun: []const u8,
    marker: []const u8,
    template: []const u8,
};

/// Shell prefix of every installed hook command. The agent runs the command
/// through `sh -c`, so outside a telar pane the guard exits before the telar
/// executable is spawned at all, mirroring the Pi extension's early return.
pub const pane_guard = "[ -n \"$TELAR_PANE_ID\" ] && [ -n \"$TELAR_PANE_GENERATION\" ] || exit 0; exec ";

/// Runs one integration command and returns the process exit code.
///
/// ```zig
/// std.process.exit(try integration.run(process_init, options));
/// ```
pub fn run(init: std.process.Init, options: IntegrationOptions) !u8 {
    if (options.agent == .pi or options.agent == .opencode) {
        return runExtension(init, options);
    }

    const integration = integrationFor(options.agent);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (options.settings) |value|
        std.mem.span(value)
    else
        try defaultSettingsPath(init.minimal.environ, integration, &path_buffer);
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = executable_buffer[0..try std.process.executablePath(init.io, &executable_buffer)];
    var commands: HookCommands = undefined;
    const hook_set, const worktree_hooks = try hookSetsFor(integration, executable, &commands);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    defer writer.flush() catch {};

    const source = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_settings_bytes)) catch |err| switch (err) {
        error.FileNotFound => try init.gpa.dupe(u8, "{}"),
        else => return err,
    };
    defer init.gpa.free(source);
    var parsed = std.json.parseFromSlice(std.json.Value, init.gpa, source, .{}) catch {
        std.debug.print("telar integration: {s} is not valid JSON\n", .{path});
        return 1;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        std.debug.print("telar integration: {s} must contain a JSON object\n", .{path});
        return 1;
    }

    switch (options.action) {
        .status => {
            for (integration.events) |event| {
                try writer.print("{s}: {s}\n", .{ event, if (hasHook(parsed.value, event, hook_set)) "installed" else "absent" });
            }
            for (integration.worktree_events) |event| {
                try writer.print("{s}: {s}\n", .{ event, if (hasHook(parsed.value, event, worktree_hooks)) "installed" else "absent" });
            }
            return 0;
        },
        .install => {
            const lifecycle_changed = try installHooks(parsed.arena.allocator(), &parsed.value, hook_set);
            const worktree_changed = try installHooks(parsed.arena.allocator(), &parsed.value, worktree_hooks);
            const changed = lifecycle_changed or worktree_changed;
            if (changed) {
                try writeSettings(init.io, path, parsed.value);
            }
            try writer.print("telar integration: {s} hooks {s} in {s}\n", .{ integration.name, if (changed) "installed" else "already present", path });
            var skill_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const skill_path = try installSkill(init.io, path, &skill_buffer);
            try writer.print("telar integration: coordinator skill written to {s}\n", .{skill_path});
            if (integration.launch_note.len != 0) {
                try writer.print("telar integration: {s}\n", .{integration.launch_note});
            }

            return 0;
        },
        .uninstall => {
            const lifecycle_changed = uninstallHooks(&parsed.value, hook_set);
            const worktree_changed = uninstallHooks(&parsed.value, worktree_hooks);
            const changed = lifecycle_changed or worktree_changed;
            if (changed) {
                try writeSettings(init.io, path, parsed.value);
            }
            try writer.print("telar integration: {s} hooks {s} in {s}\n", .{ integration.name, if (changed) "removed" else "not present", path });
            removeSkill(init.io, path);
            return 0;
        },
    }
}

fn integrationFor(agent: values.HookAgent) Integration {
    return switch (agent) {
        .claude => .{
            .name = "claude",
            .settings = core.HookSettings.claude,
            .events = &claude_events,
            .worktree_events = &claude_worktree_events,
            .timeout_seconds = 5,
        },
        .codex => .{
            .name = "codex",
            .settings = core.HookSettings.codex,
            .events = &codex_events,
            .timeout_seconds = 3,
            .launch_note = "Codex runs its hooks in its shared daemon, outside any pane, unless it starts with --no-daemon; launch it that way, for instance with `alias codex='codex --no-daemon'`",
        },
        // Hooks live in `~/.cursor/hooks.json` whatever `CURSOR_CONFIG_DIR`
        // says; Cursor reads its user hooks from the home directory.
        .cursor => .{
            .name = "cursor",
            .settings = core.HookSettings.cursor,
            .events = &cursor_events,
            .timeout_seconds = 5,
            .layout = .flat,
        },
        // Pi and OpenCode have no hook settings; `run` dispatches them to
        // `runExtension` first.
        .pi, .opencode => unreachable,
    };
}

/// Installs, removes or reports the Telar extension for Pi or plugin for
/// OpenCode. `--settings` overrides the file path.
fn runExtension(init: std.process.Init, options: IntegrationOptions) !u8 {
    const extension = extensionFor(options.agent);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (options.settings) |value|
        std.mem.span(value)
    else
        try extensionPath(init.minimal.environ, options.agent, &path_buffer);
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = executable_buffer[0..try std.process.executablePath(init.io, &executable_buffer)];
    var rendered_buffer: [max_extension_bytes]u8 = undefined;
    const rendered = try renderExtension(&rendered_buffer, extension.template, executable);
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    defer writer.flush() catch {};

    const existing: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_extension_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |bytes| init.gpa.free(bytes);
    const ours = if (existing) |bytes| isTelarExtension(bytes, extension.marker) else false;

    switch (options.action) {
        .status => {
            const state = if (existing == null) "absent" else if (ours) "installed" else "foreign";
            try writer.print(
                "telar {s}: {s} at {s}\n",
                .{
                    extension.noun,
                    state,
                    path,
                },
            );
            return 0;
        },
        .install => {
            if (existing) |bytes| {
                if (std.mem.eql(u8, bytes, rendered)) {
                    try writer.print(
                        "telar integration: {s} {s} already present at {s}\n",
                        .{
                            extension.agent,
                            extension.noun,
                            path,
                        },
                    );
                    return 0;
                }

                if (!ours) {
                    std.debug.print(
                        "telar integration: {s} exists and is not telar's {s}; move it first\n",
                        .{
                            path,
                            extension.noun,
                        },
                    );
                    return 1;
                }
            }

            try installExtension(init.io, path, rendered);
            try writer.print(
                "telar integration: {s} {s} {s} at {s}\n",
                .{
                    extension.agent,
                    extension.noun,
                    if (existing == null) "installed" else "updated",
                    path,
                },
            );
            return 0;
        },
        .uninstall => {
            if (existing == null) {
                try writer.print(
                    "telar integration: {s} {s} not present at {s}\n",
                    .{
                        extension.agent,
                        extension.noun,
                        path,
                    },
                );
                return 0;
            }

            if (!ours) {
                std.debug.print(
                    "telar integration: {s} is not telar's {s}; left untouched\n",
                    .{
                        path,
                        extension.noun,
                    },
                );
                return 1;
            }

            try std.Io.Dir.deleteFileAbsolute(init.io, path);
            try writer.print(
                "telar integration: {s} {s} removed from {s}\n",
                .{
                    extension.agent,
                    extension.noun,
                    path,
                },
            );
            return 0;
        },
    }
}

fn extensionFor(agent: values.HookAgent) Extension {
    return switch (agent) {
        .pi => .{
            .agent = "pi",
            .noun = "extension",
            .marker = pi_marker,
            .template = pi_extension_template,
        },
        .opencode => .{
            .agent = "opencode",
            .noun = "plugin",
            .marker = opencode_marker,
            .template = opencode_plugin_template,
        },
        // Hook settings agents never reach `runExtension`.
        .claude, .codex, .cursor => unreachable,
    };
}

// Pi reads `~/.pi/agent/extensions`. OpenCode scans `plugins/` in its global
// configuration directory, `$XDG_CONFIG_HOME/opencode` or `~/.config/opencode`.
fn extensionPath(environ: std.process.Environ, agent: values.HookAgent, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const home = std.process.Environ.getPosix(environ, "HOME") orelse return error.HomeUnavailable;
    if (agent == .pi) {
        return std.fmt.bufPrint(buffer, "{s}/.pi/agent/extensions/telar.ts", .{home});
    }

    if (std.process.Environ.getPosix(environ, "XDG_CONFIG_HOME")) |config| {
        if (config.len != 0) {
            return std.fmt.bufPrint(buffer, "{s}/opencode/plugins/telar.ts", .{config});
        }
    }

    return std.fmt.bufPrint(buffer, "{s}/.config/opencode/plugins/telar.ts", .{home});
}

/// Fills the Telar executable path into a bundled extension template. The
/// path is written as a JSON string, so any byte a path may contain stays
/// inert inside the TypeScript literal.
///
/// ```zig
/// const source = try renderExtension(&buffer, pi_extension_template, "/usr/local/bin/telar");
/// ```
pub fn renderExtension(buffer: []u8, template: []const u8, executable: []const u8) ![]const u8 {
    const placeholder = std.mem.indexOf(u8, template, executable_placeholder) orelse return error.InvalidTemplate;
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("{s}{f}{s}", .{
        template[0..placeholder],
        std.json.fmt(executable, .{}),
        template[placeholder + executable_placeholder.len ..],
    });
    return writer.buffered();
}

/// Reports whether a file was written by Telar, so uninstall never deletes
/// a user's own extension or plugin at the same path.
///
/// ```zig
/// if (!isTelarExtension(bytes, pi_marker)) return error.ForeignExtension;
/// ```
pub fn isTelarExtension(bytes: []const u8, marker: []const u8) bool {
    return std.mem.startsWith(u8, bytes, marker);
}

/// Creates the extension directory and replaces the file atomically with
/// owner-only permissions.
///
/// ```zig
/// try installExtension(io, "/home/me/.pi/agent/extensions/telar.ts", source);
/// ```
pub fn installExtension(io: std.Io, path: []const u8, source: []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| {
        try std.Io.Dir.cwd().createDirPath(io, directory);
    }

    var temp = try TempFile.begin(io, path);
    temp.file.writeStreamingAll(io, source) catch |err| {
        temp.discard();
        return err;
    };
    try temp.commit();
}

/// Renders the guarded shell command an agent runs on each hook event. The
/// command still ends with the marker so `hasHook` and uninstall find it.
///
/// ```zig
/// const command = try renderHookCommand(&buffer, "/opt/telar", claude_marker);
/// // [ -n "$TELAR_PANE_ID" ] && [ -n "$TELAR_PANE_GENERATION" ] || exit 0; exec '/opt/telar' hook claude
/// ```
pub fn renderHookCommand(buffer: []u8, executable: []const u8, marker: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, executable, '\'') != null) {
        return error.UnsupportedExecutablePath;
    }

    return std.fmt.bufPrint(buffer, pane_guard ++ "'{s}'{s}", .{ executable, marker });
}

/// Renders a hook command without the pane guard, for hooks an agent needs
/// answered in every session.
///
/// ```zig
/// const command = try renderUnguardedCommand(&buffer, "/opt/telar", claude_marker);
/// // exec '/opt/telar' hook claude
/// ```
pub fn renderUnguardedCommand(buffer: []u8, executable: []const u8, marker: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, executable, '\'') != null) {
        return error.UnsupportedExecutablePath;
    }

    return std.fmt.bufPrint(buffer, "exec '{s}'{s}", .{ executable, marker });
}

/// The rendered commands a pair of hook sets borrows.
const HookCommands = struct {
    lifecycle: [std.fs.max_path_bytes + pane_guard.len + 32]u8,
    worktree: [std.fs.max_path_bytes + 32]u8,
};

// The lifecycle hooks, guarded to telar panes, and the worktree hooks an
// agent needs answered in every session, both running `executable`.
fn hookSetsFor(integration: Integration, executable: []const u8, commands: *HookCommands) !struct { HookSet, HookSet } {
    const command = try renderHookCommand(&commands.lifecycle, executable, integration.settings.marker);
    const worktree_command = try renderUnguardedCommand(&commands.worktree, executable, integration.settings.marker);
    return .{
        hookSetFor(integration, command),
        .{
            .events = integration.worktree_events,
            .marker = integration.settings.marker,
            .command = worktree_command,
            .timeout_seconds = worktree_timeout_seconds,
        },
    };
}

/// Places telar's hooks for `agent` in parsed hook settings, running
/// `executable`: what `integration install` would write with that telar,
/// so `telar machine setup` can send settings the machine's own install
/// then finds already done. Returns whether anything changed.
///
/// ```zig
/// _ = try integration_support.placeHooks(arena, &settings, .claude, "/home/dev/.local/share/telar/versions/0.3.0/telar");
/// ```
pub fn placeHooks(arena: std.mem.Allocator, settings: *std.json.Value, agent: values.HookAgent, executable: []const u8) !bool {
    if (settings.* != .object) {
        return error.InvalidSettings;
    }

    var commands: HookCommands = undefined;
    const hook_set, const worktree_hooks = try hookSetsFor(integrationFor(agent), executable, &commands);
    const lifecycle_changed = try installHooks(arena, settings, hook_set);
    const worktree_changed = try installHooks(arena, settings, worktree_hooks);
    return lifecycle_changed or worktree_changed;
}

/// Whether a hook command is one of telar's, for any agent.
///
/// ```zig
/// if (integration_support.telarCommand(command)) continue;
/// ```
pub fn telarCommand(command: []const u8) bool {
    for ([_][]const u8{ claude_marker, codex_marker, cursor_marker }) |marker| {
        if (std.mem.endsWith(u8, command, marker)) {
            return true;
        }
    }

    return false;
}

fn hookSetFor(integration: Integration, command: []const u8) HookSet {
    return .{
        .events = integration.events,
        .marker = integration.settings.marker,
        .command = command,
        .timeout_seconds = integration.timeout_seconds,
        .layout = integration.layout,
    };
}

fn defaultSettingsPath(environ: std.process.Environ, integration: Integration, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const settings = integration.settings;
    const override = if (settings.environment) |name| std.process.Environ.getPosix(environ, name) else null;
    return settings.path(override, std.process.Environ.getPosix(environ, "HOME"), buffer) orelse error.HomeUnavailable;
}

/// Reports whether `event` already runs a command ending in the hook set's
/// marker.
///
/// ```zig
/// if (hasHook(settings, "Stop", .{ .events = &claude_events, .marker = claude_marker })) {
///     return;
/// }
/// ```
pub fn hasHook(settings: std.json.Value, event: []const u8, hook_set: HookSet) bool {
    const hooks = objectField(settings, "hooks") orelse return false;
    const entries = objectField(hooks, event) orelse return false;
    if (entries != .array) {
        return false;
    }

    for (entries.array.items) |entry| {
        if (entryHasCommand(entry, hook_set)) {
            return true;
        }
    }

    return false;
}

/// Adds telar's command hook to every configured event that lacks it and
/// rewrites an already installed telar hook whose command went stale, such
/// as one written before the pane guard or by a binary at another path.
///
/// ```zig
/// const hooks = HookSet{ .events = &claude_events, .marker = claude_marker, .command = command };
/// const changed = try installHooks(arena, &settings, hooks);
/// ```
pub fn installHooks(arena: std.mem.Allocator, settings: *std.json.Value, hook_set: HookSet) !bool {
    var changed = false;
    if (hook_set.layout == .flat and settings.object.get("version") == null) {
        try settings.object.put(arena, "version", .{ .integer = cursor_hooks_version });
        changed = true;
    }

    const hooks = try ensureObject(arena, &settings.object, "hooks");
    for (hook_set.events) |event| {
        const entries = try ensureArray(arena, &hooks.object, event);
        var present = false;
        for (entries.array.items) |*entry| {
            const hook = findHook(entry, hook_set) orelse continue;
            present = true;
            if (!std.mem.eql(u8, hook.object.get("command").?.string, hook_set.command)) {
                try hook.object.put(arena, "command", .{ .string = try arena.dupe(u8, hook_set.command) });
                changed = true;
            }
        }
        if (present) {
            continue;
        }

        try entries.array.append(try newEntry(arena, hook_set));
        changed = true;
    }
    return changed;
}

/// Removes every entry whose command contains `marker`; other hooks and
/// settings stay untouched.
///
/// ```zig
/// const hooks = HookSet{ .events = &claude_events, .marker = claude_marker };
/// const changed = uninstallHooks(&settings, hooks);
/// ```
pub fn uninstallHooks(settings: *std.json.Value, hook_set: HookSet) bool {
    var changed = false;
    const hooks = settings.object.getPtr("hooks") orelse return false;
    if (hooks.* != .object) {
        return false;
    }

    for (hook_set.events) |event| {
        const entries = hooks.object.getPtr(event) orelse continue;
        if (entries.* != .array) {
            continue;
        }

        var index: usize = 0;
        while (index < entries.array.items.len) {
            if (entryHasCommand(entries.array.items[index], hook_set)) {
                _ = entries.array.orderedRemove(index);
                changed = true;
            } else {
                index += 1;
            }
        }
        if (entries.array.items.len == 0) {
            _ = hooks.object.orderedRemove(event);
        }
    }
    return changed;
}

// One event entry holding telar's command: a matcher group with a `hooks`
// list for Claude Code and Codex, the command object itself for Cursor.
fn newEntry(arena: std.mem.Allocator, hook_set: HookSet) !std.json.Value {
    var hook: std.json.ObjectMap = .empty;
    if (hook_set.layout == .nested) {
        try hook.put(arena, "type", .{ .string = "command" });
    }

    try hook.put(arena, "command", .{ .string = try arena.dupe(u8, hook_set.command) });
    try hook.put(arena, "timeout", .{ .integer = hook_set.timeout_seconds });
    if (hook_set.layout == .flat) {
        return .{ .object = hook };
    }

    var list = std.json.Array.init(arena);
    try list.append(.{ .object = hook });
    var entry: std.json.ObjectMap = .empty;
    try entry.put(arena, "hooks", .{ .array = list });
    return .{ .object = entry };
}

fn entryHasCommand(entry: std.json.Value, hook_set: HookSet) bool {
    var owned = entry;
    return findHook(&owned, hook_set) != null;
}

/// Returns the first hook object in `entry` whose command ends with the
/// hook set's marker.
fn findHook(entry: *std.json.Value, hook_set: HookSet) ?*std.json.Value {
    if (entry.* != .object) {
        return null;
    }

    const marker = hook_set.marker;
    if (hook_set.layout == .flat) {
        const command = objectField(entry.*, "command") orelse return null;
        return if (command == .string and std.mem.endsWith(u8, command.string, marker)) entry else null;
    }

    const hooks = entry.object.getPtr("hooks") orelse return null;
    if (hooks.* != .array) {
        return null;
    }

    for (hooks.array.items) |*hook| {
        const command = objectField(hook.*, "command") orelse continue;
        if (command == .string and std.mem.endsWith(u8, command.string, marker)) {
            return hook;
        }
    }
    return null;
}

fn objectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) {
        return null;
    }

    return value.object.get(name);
}

fn ensureObject(arena: std.mem.Allocator, object: *std.json.ObjectMap, name: []const u8) !*std.json.Value {
    if (object.getPtr(name)) |existing| {
        if (existing.* == .object) {
            return existing;
        }

        return error.SettingsFieldNotAnObject;
    }

    try object.put(arena, name, .{ .object = .empty });
    return object.getPtr(name).?;
}

fn ensureArray(arena: std.mem.Allocator, object: *std.json.ObjectMap, name: []const u8) !*std.json.Value {
    if (object.getPtr(name)) |existing| {
        if (existing.* == .array) {
            return existing;
        }

        return error.SettingsFieldNotAnArray;
    }

    try object.put(arena, name, .{ .array = std.json.Array.init(arena) });
    return object.getPtr(name).?;
}

/// Writes the coordinator skill into `skills/telar-coordinator/SKILL.md`
/// beside the agent's settings file and returns its path.
fn installSkill(io: std.Io, settings_path: []const u8, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const directory = std.fs.path.dirname(settings_path) orelse return error.InvalidSettingsPath;
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const skill_directory = try std.fmt.bufPrint(&directory_buffer, "{s}/{s}", .{ directory, coordinator_skill_directory });
    try std.Io.Dir.cwd().createDirPath(io, skill_directory);
    const path = try std.fmt.bufPrint(buffer, "{s}/SKILL.md", .{skill_directory});
    var temp = try TempFile.begin(io, path);
    var file_buffer: [4096]u8 = undefined;
    var file_writer = temp.file.writerStreaming(io, &file_buffer);
    file_writer.interface.writeAll(coordinator_skill_header ++ skill.coordinator_text) catch |err| {
        temp.discard();
        return err;
    };
    file_writer.interface.flush() catch |err| {
        temp.discard();
        return err;
    };
    try temp.commit();
    return path;
}

fn removeSkill(io: std.Io, settings_path: []const u8) void {
    const directory = std.fs.path.dirname(settings_path) orelse return;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/{s}/SKILL.md", .{ directory, coordinator_skill_directory }) catch return;
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

// An agent that never ran has no settings directory yet.
fn writeSettings(io: std.Io, path: []const u8, settings: std.json.Value) !void {
    if (std.fs.path.dirname(path)) |directory| {
        try std.Io.Dir.cwd().createDirPath(io, directory);
    }

    var temp = try TempFile.begin(io, path);
    var buffer: [16 * 1024]u8 = undefined;
    var file_writer = temp.file.writerStreaming(io, &buffer);
    file_writer.interface.print("{f}\n", .{std.json.fmt(settings, .{ .whitespace = .indent_2 })}) catch |err| {
        temp.discard();
        return err;
    };
    file_writer.interface.flush() catch |err| {
        temp.discard();
        return err;
    };
    try temp.commit();
}

test "Claude install adds telar hooks once and uninstall removes only them" {
    const source =
        \\{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"other.sh"}]}]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const arena = parsed.arena.allocator();

    const hook_set = hookSetFor(integrationFor(.claude), "/opt/telar hook claude");
    try std.testing.expect(try installHooks(arena, &parsed.value, hook_set));
    try std.testing.expect(!try installHooks(arena, &parsed.value, hook_set));
    for (claude_events) |event| {
        try std.testing.expect(hasHook(parsed.value, event, hook_set));
    }
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("hooks").?.object.get("Stop").?.array.items.len);
    const claude_timeout = parsed.value.object.get("hooks").?.object.get("SessionEnd").?.array.items[0].object.get("hooks").?.array.items[0].object.get("timeout").?.integer;
    try std.testing.expectEqual(@as(i64, 5), claude_timeout);
    try std.testing.expectEqualStrings("opus", parsed.value.object.get("model").?.string);

    try std.testing.expect(uninstallHooks(&parsed.value, hook_set));
    try std.testing.expect(!uninstallHooks(&parsed.value, hook_set));
    try std.testing.expect(!hasHook(parsed.value, "SessionStart", hook_set));
    const stop = parsed.value.object.get("hooks").?.object.get("Stop").?.array;
    try std.testing.expectEqual(@as(usize, 1), stop.items.len);
    try std.testing.expect(parsed.value.object.get("hooks").?.object.get("SessionStart") == null);
}

test "hook commands are guarded by the pane environment and keep the marker" {
    var buffer: [256]u8 = undefined;
    const command = try renderHookCommand(&buffer, "/opt/tel ar/telar", claude_marker);
    try std.testing.expectEqualStrings("[ -n \"$TELAR_PANE_ID\" ] && [ -n \"$TELAR_PANE_GENERATION\" ] || exit 0; exec '/opt/tel ar/telar' hook claude", command);
    try std.testing.expect(std.mem.endsWith(u8, command, claude_marker));
    try std.testing.expectError(error.UnsupportedExecutablePath, renderHookCommand(&buffer, "/opt/it's/telar", claude_marker));
}

test "install rewrites a stale telar hook command in place" {
    const source =
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/old/telar hook claude","timeout":5}]}]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const arena = parsed.arena.allocator();
    var buffer: [256]u8 = undefined;
    const command = try renderHookCommand(&buffer, "/opt/telar", claude_marker);
    const hook_set = hookSetFor(integrationFor(.claude), command);

    try std.testing.expect(try installHooks(arena, &parsed.value, hook_set));
    const stop = parsed.value.object.get("hooks").?.object.get("Stop").?.array;
    try std.testing.expectEqual(@as(usize, 1), stop.items.len);
    try std.testing.expectEqualStrings(command, stop.items[0].object.get("hooks").?.array.items[0].object.get("command").?.string);
    try std.testing.expect(!try installHooks(arena, &parsed.value, hook_set));
}

test "Codex install owns only its lifecycle events" {
    const source =
        \\{"hooks":{"Notification":[{"hooks":[{"type":"command","command":"other.sh"}]}]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const hook_set = hookSetFor(integrationFor(.codex), "/opt/telar hook codex");

    try std.testing.expect(try installHooks(parsed.arena.allocator(), &parsed.value, hook_set));
    try std.testing.expect(!try installHooks(parsed.arena.allocator(), &parsed.value, hook_set));
    for (codex_events) |event| {
        try std.testing.expect(hasHook(parsed.value, event, hook_set));
    }
    const codex_timeout = parsed.value.object.get("hooks").?.object.get("SessionEnd").?.array.items[0].object.get("hooks").?.array.items[0].object.get("timeout").?.integer;
    try std.testing.expectEqual(@as(i64, 3), codex_timeout);
    try std.testing.expect(parsed.value.object.get("hooks").?.object.get("Notification") != null);

    try std.testing.expect(uninstallHooks(&parsed.value, hook_set));
    try std.testing.expect(parsed.value.object.get("hooks").?.object.get("Notification") != null);
    try std.testing.expect(parsed.value.object.get("hooks").?.object.get("PermissionRequest") == null);
}

test "Cursor install writes flat command hooks beside another tool's and keeps its version" {
    const source =
        \\{"version":1,"hooks":{"sessionStart":[{"command":"/Users/me/.config/herdr/cursor/herdr-agent-state.sh session","timeout":10}]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const arena = parsed.arena.allocator();
    var buffer: [256]u8 = undefined;
    const command = try renderHookCommand(&buffer, "/opt/telar", cursor_marker);
    const hook_set = hookSetFor(integrationFor(.cursor), command);

    try std.testing.expect(try installHooks(arena, &parsed.value, hook_set));
    try std.testing.expect(!try installHooks(arena, &parsed.value, hook_set));
    for (cursor_events) |event| {
        try std.testing.expect(hasHook(parsed.value, event, hook_set));
    }

    const session_start = parsed.value.object.get("hooks").?.object.get("sessionStart").?.array;
    try std.testing.expectEqual(@as(usize, 2), session_start.items.len);
    const ours = session_start.items[1].object;
    try std.testing.expectEqualStrings(command, ours.get("command").?.string);
    try std.testing.expectEqual(@as(i64, 5), ours.get("timeout").?.integer);
    try std.testing.expect(ours.get("type") == null);
    try std.testing.expect(ours.get("hooks") == null);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("version").?.integer);

    try std.testing.expect(uninstallHooks(&parsed.value, hook_set));
    try std.testing.expect(!hasHook(parsed.value, "stop", hook_set));
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("hooks").?.object.get("sessionStart").?.array.items.len);
    try std.testing.expect(parsed.value.object.get("hooks").?.object.get("stop") == null);
}

test "Cursor install starts an absent hooks file at schema version 1 and rewrites a stale command" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer parsed.deinit();
    const arena = parsed.arena.allocator();
    const stale = hookSetFor(integrationFor(.cursor), "/old/telar hook cursor");
    try std.testing.expect(try installHooks(arena, &parsed.value, stale));
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("version").?.integer);

    const current = hookSetFor(integrationFor(.cursor), "/opt/telar hook cursor");
    try std.testing.expect(try installHooks(arena, &parsed.value, current));
    const stop = parsed.value.object.get("hooks").?.object.get("stop").?.array;
    try std.testing.expectEqual(@as(usize, 1), stop.items.len);
    try std.testing.expectEqualStrings("/opt/telar hook cursor", stop.items[0].object.get("command").?.string);

    // A Claude-shaped entry that happens to end in the marker is not Cursor's.
    try std.testing.expect(!hasHook(parsed.value, "stop", hookSetFor(integrationFor(.claude), "/opt/telar hook cursor")));
}

test "Codex settings prefer CODEX_HOME while Claude uses HOME" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", "/home/adrian");
    try environment.put("CODEX_HOME", "/state/codex");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const environ: std.process.Environ = .{ .block = block };
    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("/state/codex/hooks.json", try defaultSettingsPath(environ, integrationFor(.codex), &buffer));
    try std.testing.expectEqualStrings("/home/adrian/.claude/settings.json", try defaultSettingsPath(environ, integrationFor(.claude), &buffer));
    try std.testing.expectEqualStrings("/home/adrian/.cursor/hooks.json", try defaultSettingsPath(environ, integrationFor(.cursor), &buffer));
    try std.testing.expectEqualStrings("/home/adrian/.pi/agent/extensions/telar.ts", try extensionPath(environ, .pi, &buffer));
    try std.testing.expectEqualStrings("/home/adrian/.config/opencode/plugins/telar.ts", try extensionPath(environ, .opencode, &buffer));

    try environment.put("XDG_CONFIG_HOME", "/state/config");
    const xdg_block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer xdg_block.deinit(std.testing.allocator);
    const xdg_environ: std.process.Environ = .{ .block = xdg_block };
    try std.testing.expectEqualStrings("/state/config/opencode/plugins/telar.ts", try extensionPath(xdg_environ, .opencode, &buffer));
    try std.testing.expectEqualStrings("/home/adrian/.pi/agent/extensions/telar.ts", try extensionPath(xdg_environ, .pi, &buffer));
}

test "the Pi extension is rendered with the executable path as a string literal" {
    var buffer: [max_extension_bytes]u8 = undefined;
    const source = try renderExtension(&buffer, pi_extension_template, "/opt/tel\"ar/bin/telar");
    try std.testing.expect(isTelarExtension(source, pi_marker));
    try std.testing.expect(std.mem.indexOf(u8, source, "const TELAR = \"/opt/tel\\\"ar/bin/telar\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "__TELAR_EXECUTABLE__") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "[\"hook\", \"pi\"]") != null);
    try std.testing.expect(!isTelarExtension("export default function () {}", pi_marker));
}

test "the OpenCode plugin is rendered with the executable path and only its own marker" {
    var buffer: [max_extension_bytes]u8 = undefined;
    const source = try renderExtension(&buffer, opencode_plugin_template, "/opt/telar");
    try std.testing.expect(isTelarExtension(source, opencode_marker));
    try std.testing.expect(!isTelarExtension(source, pi_marker));
    try std.testing.expect(std.mem.indexOf(u8, source, "const TELAR = \"/opt/telar\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "__TELAR_EXECUTABLE__") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "[\"hook\", \"opencode\"]") != null);
}

test "the Pi extension is installed atomically under a fresh directory" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/agent/extensions/telar.ts", .{directory_buffer[0..directory_len]});

    var source_buffer: [max_extension_bytes]u8 = undefined;
    const source = try renderExtension(&source_buffer, pi_extension_template, "/opt/telar");
    try installExtension(io, path, source);
    try installExtension(io, path, source);

    const written = try std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(max_extension_bytes));
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(source, written);
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));

    var temp_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try std.fmt.bufPrint(&temp_path_buffer, "{s}.telar-tmp", .{path});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, temp_path, .{}));
}
