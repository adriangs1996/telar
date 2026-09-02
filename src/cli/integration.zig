//! `telar integration install|uninstall|status <agent>`: registers telar's
//! hook command in an agent's settings so its lifecycle reaches the runtime
//! as official reports.

const std = @import("std");
const parser = @import("parser.zig");

const Io = std.Io;
const File = Io.File;
const max_settings_bytes = 4 * 1024 * 1024;

pub const claude_events = [_][]const u8{ "SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd" };
pub const codex_events = [_][]const u8{ "SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd" };
pub const claude_marker = " hook claude";
pub const codex_marker = " hook codex";

const Integration = struct {
    name: []const u8,
    settings_environment: ?[]const u8,
    settings_directory: []const u8,
    settings_file: []const u8,
    marker: []const u8,
    events: []const []const u8,
    timeout_seconds: i64,
};

pub const HookSet = struct {
    events: []const []const u8,
    marker: []const u8,
    command: []const u8 = "",
    timeout_seconds: i64 = 5,
};

/// Runs one integration command and returns the process exit code.
///
/// ```zig
/// std.process.exit(try integration.run(process_init, options));
/// ```
pub fn run(init: std.process.Init, options: parser.IntegrationOptions) !u8 {
    const integration = integrationFor(options.agent);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (options.settings) |value|
        std.mem.span(value)
    else
        try defaultSettingsPath(init.minimal.environ, integration, &path_buffer);
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = executable_buffer[0..try std.process.executablePath(init.io, &executable_buffer)];
    var command_buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buffer, "{s}{s}", .{ executable, integration.marker });
    const hook_set = hookSetFor(integration, command);
    var output_buffer: [4096]u8 = undefined;
    var output = File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    defer writer.flush() catch {};

    const source = Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_settings_bytes)) catch |err| switch (err) {
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
                try writer.print("{s}: {s}\n", .{ event, if (hasHook(parsed.value, event, integration.marker)) "installed" else "absent" });
            }
            return 0;
        },
        .install => {
            const changed = try installHooks(parsed.arena.allocator(), &parsed.value, hook_set);
            if (changed) {
                try writeSettings(init.io, path, parsed.value);
            }
            try writer.print("telar integration: {s} hooks {s} in {s}\n", .{ integration.name, if (changed) "installed" else "already present", path });
            return 0;
        },
        .uninstall => {
            const changed = uninstallHooks(&parsed.value, hook_set);
            if (changed) {
                try writeSettings(init.io, path, parsed.value);
            }
            try writer.print("telar integration: {s} hooks {s} in {s}\n", .{ integration.name, if (changed) "removed" else "not present", path });
            return 0;
        },
    }
}

fn integrationFor(agent: parser.HookAgent) Integration {
    return switch (agent) {
        .claude => .{
            .name = "claude",
            .settings_environment = null,
            .settings_directory = ".claude",
            .settings_file = "settings.json",
            .marker = claude_marker,
            .events = &claude_events,
            .timeout_seconds = 5,
        },
        .codex => .{
            .name = "codex",
            .settings_environment = "CODEX_HOME",
            .settings_directory = ".codex",
            .settings_file = "hooks.json",
            .marker = codex_marker,
            .events = &codex_events,
            .timeout_seconds = 3,
        },
    };
}

fn hookSetFor(integration: Integration, command: []const u8) HookSet {
    return .{
        .events = integration.events,
        .marker = integration.marker,
        .command = command,
        .timeout_seconds = integration.timeout_seconds,
    };
}

fn defaultSettingsPath(environ: std.process.Environ, integration: Integration, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    if (integration.settings_environment) |environment_name| {
        if (std.process.Environ.getPosix(environ, environment_name)) |settings_directory| {
            if (settings_directory.len != 0) {
                return std.fmt.bufPrint(buffer, "{s}/{s}", .{ settings_directory, integration.settings_file });
            }
        }
    }

    const home = std.process.Environ.getPosix(environ, "HOME") orelse return error.HomeUnavailable;
    return std.fmt.bufPrint(buffer, "{s}/{s}/{s}", .{ home, integration.settings_directory, integration.settings_file });
}

/// Reports whether `event` already runs a command containing `marker`.
///
/// ```zig
/// if (hasHook(settings, "Stop", " hook claude")) {
///     return;
/// }
/// ```
pub fn hasHook(settings: std.json.Value, event: []const u8, marker: []const u8) bool {
    const hooks = objectField(settings, "hooks") orelse return false;
    const entries = objectField(hooks, event) orelse return false;
    if (entries != .array) {
        return false;
    }

    for (entries.array.items) |entry| {
        if (entryHasCommand(entry, marker)) {
            return true;
        }
    }

    return false;
}

/// Adds telar's command hook to every configured event that lacks it.
///
/// ```zig
/// const hooks = HookSet{ .events = &claude_events, .marker = claude_marker, .command = command };
/// const changed = try installHooks(arena, &settings, hooks);
/// ```
pub fn installHooks(arena: std.mem.Allocator, settings: *std.json.Value, hook_set: HookSet) !bool {
    var changed = false;
    const hooks = try ensureObject(arena, &settings.object, "hooks");
    for (hook_set.events) |event| {
        const entries = try ensureArray(arena, &hooks.object, event);
        var present = false;
        for (entries.array.items) |entry| {
            if (entryHasCommand(entry, hook_set.marker)) {
                present = true;
            }
        }
        if (present) {
            continue;
        }

        var hook: std.json.ObjectMap = .empty;
        try hook.put(arena, "type", .{ .string = "command" });
        try hook.put(arena, "command", .{ .string = try arena.dupe(u8, hook_set.command) });
        try hook.put(arena, "timeout", .{ .integer = hook_set.timeout_seconds });
        var list = std.json.Array.init(arena);
        try list.append(.{ .object = hook });
        var entry: std.json.ObjectMap = .empty;
        try entry.put(arena, "hooks", .{ .array = list });
        try entries.array.append(.{ .object = entry });
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
            if (entryHasCommand(entries.array.items[index], hook_set.marker)) {
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

fn entryHasCommand(entry: std.json.Value, marker: []const u8) bool {
    const hooks = objectField(entry, "hooks") orelse return false;
    if (hooks != .array) {
        return false;
    }

    for (hooks.array.items) |hook| {
        const command = objectField(hook, "command") orelse continue;
        if (command == .string and std.mem.endsWith(u8, command.string, marker)) {
            return true;
        }
    }
    return false;
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

fn writeSettings(io: Io, path: []const u8, settings: std.json.Value) !void {
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try std.fmt.bufPrint(&temp_buffer, "{s}.telar-tmp", .{path});
    const file = try Io.Dir.createFileAbsolute(io, temp_path, .{ .truncate = true, .permissions = File.Permissions.fromMode(0o600) });
    var buffer: [16 * 1024]u8 = undefined;
    var file_writer = file.writerStreaming(io, &buffer);
    file_writer.interface.print("{f}\n", .{std.json.fmt(settings, .{ .whitespace = .indent_2 })}) catch |err| {
        file.close(io);
        Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return err;
    };
    file_writer.interface.flush() catch |err| {
        file.close(io);
        Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return err;
    };
    file.close(io);
    try Io.Dir.renameAbsolute(temp_path, path, io);
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
        try std.testing.expect(hasHook(parsed.value, event, claude_marker));
    }
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("hooks").?.object.get("Stop").?.array.items.len);
    const claude_timeout = parsed.value.object.get("hooks").?.object.get("SessionEnd").?.array.items[0].object.get("hooks").?.array.items[0].object.get("timeout").?.integer;
    try std.testing.expectEqual(@as(i64, 5), claude_timeout);
    try std.testing.expectEqualStrings("opus", parsed.value.object.get("model").?.string);

    try std.testing.expect(uninstallHooks(&parsed.value, hook_set));
    try std.testing.expect(!uninstallHooks(&parsed.value, hook_set));
    try std.testing.expect(!hasHook(parsed.value, "SessionStart", claude_marker));
    const stop = parsed.value.object.get("hooks").?.object.get("Stop").?.array;
    try std.testing.expectEqual(@as(usize, 1), stop.items.len);
    try std.testing.expect(parsed.value.object.get("hooks").?.object.get("SessionStart") == null);
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
        try std.testing.expect(hasHook(parsed.value, event, codex_marker));
    }
    const codex_timeout = parsed.value.object.get("hooks").?.object.get("SessionEnd").?.array.items[0].object.get("hooks").?.array.items[0].object.get("timeout").?.integer;
    try std.testing.expectEqual(@as(i64, 3), codex_timeout);
    try std.testing.expect(parsed.value.object.get("hooks").?.object.get("Notification") != null);

    try std.testing.expect(uninstallHooks(&parsed.value, hook_set));
    try std.testing.expect(parsed.value.object.get("hooks").?.object.get("Notification") != null);
    try std.testing.expect(parsed.value.object.get("hooks").?.object.get("PermissionRequest") == null);
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
}
