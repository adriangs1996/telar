//! `telar integration install|uninstall|status <agent>`: registers telar's
//! hook command in an agent's settings so its lifecycle reaches the runtime
//! as official reports.

const std = @import("std");
const parser = @import("parser.zig");

const Io = std.Io;
const File = Io.File;
const max_settings_bytes = 4 * 1024 * 1024;

pub const claude_events = [_][]const u8{ "SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd" };
pub const claude_marker = " hook claude";

/// Runs one integration command and returns the process exit code.
///
/// ```zig
/// std.process.exit(try integration.run(process_init, options));
/// ```
pub fn run(init: std.process.Init, options: parser.IntegrationOptions) !u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try settingsPath(init.minimal.environ, options.settings, &path_buffer);
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = executable_buffer[0..try std.process.executablePath(init.io, &executable_buffer)];
    var command_buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buffer, "{s}{s}", .{ executable, claude_marker });
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
            for (claude_events) |event| {
                try writer.print("{s}: {s}\n", .{ event, if (hasHook(parsed.value, event, claude_marker)) "installed" else "absent" });
            }
            return 0;
        },
        .install => {
            const changed = try installHooks(parsed.arena.allocator(), &parsed.value, command);
            if (changed) try writeSettings(init.io, path, parsed.value);
            try writer.print("telar integration: claude hooks {s} in {s}\n", .{ if (changed) "installed" else "already present", path });
            return 0;
        },
        .uninstall => {
            const changed = uninstallHooks(&parsed.value, claude_marker);
            if (changed) try writeSettings(init.io, path, parsed.value);
            try writer.print("telar integration: claude hooks {s} in {s}\n", .{ if (changed) "removed" else "not present", path });
            return 0;
        },
    }
}

fn settingsPath(environ: std.process.Environ, override: ?[*:0]const u8, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    if (override) |value| return std.mem.span(value);
    const home = std.process.Environ.getPosix(environ, "HOME") orelse return error.HomeUnavailable;
    return std.fmt.bufPrint(buffer, "{s}/.claude/settings.json", .{home});
}

/// Reports whether `event` already runs a command containing `marker`.
///
/// ```zig
/// if (hasHook(settings, "Stop", " hook claude")) return;
/// ```
pub fn hasHook(settings: std.json.Value, event: []const u8, marker: []const u8) bool {
    const hooks = objectField(settings, "hooks") orelse return false;
    const entries = objectField(hooks, event) orelse return false;
    if (entries != .array) return false;
    for (entries.array.items) |entry| {
        if (entryHasCommand(entry, marker)) return true;
    }
    return false;
}

/// Adds telar's command hook to every Claude event that lacks it.
///
/// ```zig
/// const changed = try installHooks(arena, &settings, "/usr/local/bin/telar hook claude");
/// ```
pub fn installHooks(arena: std.mem.Allocator, settings: *std.json.Value, command: []const u8) !bool {
    var changed = false;
    const hooks = try ensureObject(arena, &settings.object, "hooks");
    for (claude_events) |event| {
        const entries = try ensureArray(arena, &hooks.object, event);
        var present = false;
        for (entries.array.items) |entry| {
            if (entryHasCommand(entry, claude_marker)) present = true;
        }
        if (present) continue;

        var hook: std.json.ObjectMap = .empty;
        try hook.put(arena, "type", .{ .string = "command" });
        try hook.put(arena, "command", .{ .string = try arena.dupe(u8, command) });
        try hook.put(arena, "timeout", .{ .integer = 5 });
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
/// const changed = uninstallHooks(&settings, " hook claude");
/// ```
pub fn uninstallHooks(settings: *std.json.Value, marker: []const u8) bool {
    var changed = false;
    const hooks = settings.object.getPtr("hooks") orelse return false;
    if (hooks.* != .object) return false;
    for (claude_events) |event| {
        const entries = hooks.object.getPtr(event) orelse continue;
        if (entries.* != .array) continue;
        var index: usize = 0;
        while (index < entries.array.items.len) {
            if (entryHasCommand(entries.array.items[index], marker)) {
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
    if (hooks != .array) return false;
    for (hooks.array.items) |hook| {
        const command = objectField(hook, "command") orelse continue;
        if (command == .string and std.mem.endsWith(u8, command.string, marker)) return true;
    }
    return false;
}

fn objectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn ensureObject(arena: std.mem.Allocator, object: *std.json.ObjectMap, name: []const u8) !*std.json.Value {
    if (object.getPtr(name)) |existing| {
        if (existing.* == .object) return existing;
        return error.SettingsFieldNotAnObject;
    }
    try object.put(arena, name, .{ .object = .empty });
    return object.getPtr(name).?;
}

fn ensureArray(arena: std.mem.Allocator, object: *std.json.ObjectMap, name: []const u8) !*std.json.Value {
    if (object.getPtr(name)) |existing| {
        if (existing.* == .array) return existing;
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

test "install adds telar hooks once and uninstall removes only them" {
    const source =
        \\{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"other.sh"}]}]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const arena = parsed.arena.allocator();

    try std.testing.expect(try installHooks(arena, &parsed.value, "/opt/telar hook claude"));
    try std.testing.expect(!try installHooks(arena, &parsed.value, "/opt/telar hook claude"));
    for (claude_events) |event| try std.testing.expect(hasHook(parsed.value, event, claude_marker));
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("hooks").?.object.get("Stop").?.array.items.len);
    try std.testing.expectEqualStrings("opus", parsed.value.object.get("model").?.string);

    try std.testing.expect(uninstallHooks(&parsed.value, claude_marker));
    try std.testing.expect(!uninstallHooks(&parsed.value, claude_marker));
    try std.testing.expect(!hasHook(parsed.value, "SessionStart", claude_marker));
    const stop = parsed.value.object.get("hooks").?.object.get("Stop").?.array;
    try std.testing.expectEqual(@as(usize, 1), stop.items.len);
    try std.testing.expect(parsed.value.object.get("hooks").?.object.get("SessionStart") == null);
}
