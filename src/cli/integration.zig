//! `telar integration install|uninstall|status <agent>`: registers telar's
//! lifecycle reporting with an agent so its official events reach the
//! runtime. Claude Code gets a command hook in its settings file; Pi gets a
//! Telar extension in its global extension directory.

const std = @import("std");
const parser = @import("parser.zig");

const Io = std.Io;
const File = Io.File;
const max_settings_bytes = 4 * 1024 * 1024;
const max_extension_bytes = 64 * 1024;

pub const claude_events = [_][]const u8{ "SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd" };
pub const claude_marker = " hook claude";

/// First line of the extension Telar writes for Pi; uninstall touches only
/// files that start with it.
pub const pi_marker = "// telar-integration: pi";
pub const pi_extension_template = @embedFile("integration/pi.ts");
const pi_executable_placeholder = "\"__TELAR_EXECUTABLE__\"";

const Invocation = struct {
    init: std.process.Init,
    options: parser.IntegrationOptions,
    executable: []const u8,
    writer: *Io.Writer,
};

/// Runs one integration command and returns the process exit code.
///
/// ```zig
/// std.process.exit(try integration.run(process_init, options));
/// ```
pub fn run(init: std.process.Init, options: parser.IntegrationOptions) !u8 {
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = executable_buffer[0..try std.process.executablePath(init.io, &executable_buffer)];
    var output_buffer: [4096]u8 = undefined;
    var output = File.stdout().writerStreaming(init.io, &output_buffer);
    defer output.interface.flush() catch {};

    const invocation: Invocation = .{
        .init = init,
        .options = options,
        .executable = executable,
        .writer = &output.interface,
    };

    return switch (options.agent) {
        .claude => runClaude(&invocation),
        .pi => runPi(&invocation),
    };
}

fn runClaude(invocation: *const Invocation) !u8 {
    const init = invocation.init;
    const options = invocation.options;
    const writer = invocation.writer;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try settingsPath(init.minimal.environ, options.settings, &path_buffer);
    var command_buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buffer, "{s}{s}", .{ invocation.executable, claude_marker });

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

fn runPi(invocation: *const Invocation) !u8 {
    const init = invocation.init;
    const options = invocation.options;
    const writer = invocation.writer;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try piExtensionPath(init.minimal.environ, options.settings, &path_buffer);
    var rendered_buffer: [max_extension_bytes]u8 = undefined;
    const rendered = try renderPiExtension(&rendered_buffer, invocation.executable);

    const existing: ?[]u8 = Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_extension_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |bytes| init.gpa.free(bytes);
    const ours = if (existing) |bytes| isTelarExtension(bytes) else false;

    switch (options.action) {
        .status => {
            const state = if (existing == null) "absent" else if (ours) "installed" else "foreign";
            try writer.print("telar extension: {s} at {s}\n", .{ state, path });
            return 0;
        },
        .install => {
            if (existing) |bytes| {
                if (std.mem.eql(u8, bytes, rendered)) {
                    try writer.print("telar integration: pi extension already present at {s}\n", .{path});
                    return 0;
                }

                if (!ours) {
                    std.debug.print("telar integration: {s} exists and is not telar's extension; move it first\n", .{path});
                    return 1;
                }
            }

            try installPiExtension(init.io, path, rendered);
            try writer.print("telar integration: pi extension {s} at {s}\n", .{ if (existing == null) "installed" else "updated", path });
            return 0;
        },
        .uninstall => {
            if (existing == null) {
                try writer.print("telar integration: pi extension not present at {s}\n", .{path});
                return 0;
            }

            if (!ours) {
                std.debug.print("telar integration: {s} is not telar's extension; left untouched\n", .{path});
                return 1;
            }

            try Io.Dir.deleteFileAbsolute(init.io, path);
            try writer.print("telar integration: pi extension removed from {s}\n", .{path});
            return 0;
        },
    }
}

fn settingsPath(environ: std.process.Environ, override: ?[*:0]const u8, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    if (override) |value| return std.mem.span(value);
    const home = std.process.Environ.getPosix(environ, "HOME") orelse return error.HomeUnavailable;
    return std.fmt.bufPrint(buffer, "{s}/.claude/settings.json", .{home});
}

fn piExtensionPath(environ: std.process.Environ, override: ?[*:0]const u8, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    if (override) |value| return std.mem.span(value);
    const home = std.process.Environ.getPosix(environ, "HOME") orelse return error.HomeUnavailable;
    return std.fmt.bufPrint(buffer, "{s}/.pi/agent/extensions/telar.ts", .{home});
}

/// Fills the Telar executable path into the bundled Pi extension. The path
/// is written as a JSON string, so any byte a path may contain stays inert
/// inside the TypeScript literal.
///
/// ```zig
/// const source = try renderPiExtension(&buffer, "/usr/local/bin/telar");
/// ```
pub fn renderPiExtension(buffer: []u8, executable: []const u8) ![]const u8 {
    const placeholder = std.mem.indexOf(u8, pi_extension_template, pi_executable_placeholder) orelse return error.InvalidTemplate;
    var writer: Io.Writer = .fixed(buffer);
    try writer.print("{s}{f}{s}", .{
        pi_extension_template[0..placeholder],
        std.json.fmt(executable, .{}),
        pi_extension_template[placeholder + pi_executable_placeholder.len ..],
    });
    return writer.buffered();
}

/// Reports whether a file was written by Telar, so uninstall never deletes
/// a user's own extension at the same path.
///
/// ```zig
/// if (!isTelarExtension(bytes)) return error.ForeignExtension;
/// ```
pub fn isTelarExtension(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, pi_marker);
}

/// Creates the extension directory and replaces the file atomically with
/// owner-only permissions.
///
/// ```zig
/// try installPiExtension(io, "/home/me/.pi/agent/extensions/telar.ts", source);
/// ```
pub fn installPiExtension(io: Io, path: []const u8, source: []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| {
        try Io.Dir.cwd().createDirPath(io, directory);
    }

    var temp = try TempFile.begin(io, path);
    temp.file.writeStreamingAll(io, source) catch |err| {
        temp.discard();
        return err;
    };
    try temp.commit();
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

/// An owner-only temporary next to `path`, renamed over it on commit.
const TempFile = struct {
    io: Io,
    file: File,
    path: []const u8,
    temp_buffer: [std.fs.max_path_bytes]u8 = undefined,
    temp_len: usize = 0,

    fn begin(io: Io, path: []const u8) !TempFile {
        var temp: TempFile = .{ .io = io, .file = undefined, .path = path };
        const temp_path = try std.fmt.bufPrint(&temp.temp_buffer, "{s}.telar-tmp", .{path});
        temp.temp_len = temp_path.len;
        temp.file = try Io.Dir.createFileAbsolute(io, temp_path, .{ .truncate = true, .permissions = File.Permissions.fromMode(0o600) });
        return temp;
    }

    fn tempPath(temp: *const TempFile) []const u8 {
        return temp.temp_buffer[0..temp.temp_len];
    }

    fn commit(temp: *TempFile) !void {
        temp.file.close(temp.io);
        try Io.Dir.renameAbsolute(temp.tempPath(), temp.path, temp.io);
    }

    fn discard(temp: *TempFile) void {
        temp.file.close(temp.io);
        Io.Dir.deleteFileAbsolute(temp.io, temp.tempPath()) catch {};
    }
};

fn writeSettings(io: Io, path: []const u8, settings: std.json.Value) !void {
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

test "the Pi extension is rendered with the executable path as a string literal" {
    var buffer: [max_extension_bytes]u8 = undefined;
    const source = try renderPiExtension(&buffer, "/opt/tel\"ar/bin/telar");
    try std.testing.expect(isTelarExtension(source));
    try std.testing.expect(std.mem.indexOf(u8, source, "const TELAR = \"/opt/tel\\\"ar/bin/telar\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "__TELAR_EXECUTABLE__") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "[\"hook\", \"pi\"]") != null);
    try std.testing.expect(!isTelarExtension("export default function () {}"));
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
    const source = try renderPiExtension(&source_buffer, "/opt/telar");
    try installPiExtension(io, path, source);
    try installPiExtension(io, path, source);

    const written = try Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(max_extension_bytes));
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(source, written);
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));

    var temp_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try std.fmt.bufPrint(&temp_path_buffer, "{s}.telar-tmp", .{path});
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, temp_path, .{}));
}
