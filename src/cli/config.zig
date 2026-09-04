//! Configuration loading shared by CLI entrypoints and `telar config check`.

const std = @import("std");
const frontend = @import("telar-frontend");
const parser = @import("parser.zig");

const Io = std.Io;
const File = Io.File;

pub const Selection = struct {
    path: ?[*:0]const u8 = null,
    disabled: bool = false,
    profile: ?[*:0]const u8 = null,
};

/// Loads one config generation or returns null when configuration is disabled
/// or the implicit default file does not exist.
///
/// ```zig
/// const generation = try config.loadGeneration(process_init, .{}, &path_buffer);
/// defer if (generation) |value| value.deinit();
/// ```
pub fn loadGeneration(init: std.process.Init, selection: Selection, path_buffer: []u8) !?*frontend.config.Generation {
    if (selection.disabled) {
        return null;
    }

    const selected = try resolveSelection(init.minimal.environ, selection, path_buffer);
    Io.Dir.cwd().access(init.io, selected.path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (selected.explicit) {
                return err;
            }

            return null;
        },
        else => |other| return other,
    };
    var diagnostic: frontend.config.Diagnostic = .{};
    return frontend.config.Generation.loadFile(.{
        .gpa = init.gpa,
        .io = init.io,
        .diagnostic = &diagnostic,
    }, .{
        .path = selected.path,
        .number = 1,
        .profile = if (selection.profile) |value| std.mem.span(value) else null,
    }) catch |err| {
        std.debug.print("telar config: {s}\n", .{diagnostic.message()});
        return err;
    };
}

/// Compiles a requested configuration, its plugin declarations and keymap,
/// then prints success without starting either Telar process.
///
/// ```zig
/// try config.runCheck(process_init, options);
/// ```
pub fn runCheck(init: std.process.Init, options: parser.ConfigCheckOptions) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (options.path) |value|
        std.mem.span(value)
    else
        try frontend.config.defaultPath(init.minimal.environ, &path_buffer);
    var diagnostic: frontend.config.Diagnostic = .{};
    const generation = frontend.config.Generation.loadFile(.{
        .gpa = init.gpa,
        .io = init.io,
        .diagnostic = &diagnostic,
    }, .{
        .path = path,
        .number = 1,
        .profile = if (options.profile) |value| std.mem.span(value) else null,
    }) catch |err| {
        std.debug.print("telar config: {s}\n", .{diagnostic.message()});
        return err;
    };
    defer generation.deinit();

    const registry = try frontend.plugins.Registry.load(.{
        .gpa = init.gpa,
        .io = init.io,
        .config_dir = generation.configDir(),
    }, generation.pluginSlice());
    try registry.validateConfiguredActions(generation.snapshot.bindingSlice());
    frontend.config.validateKeymap(generation.snapshot.prefix, generation.snapshot.bindingSlice()) catch |err| {
        std.debug.print("telar config: keybindings do not compile: {s}\n", .{@errorName(err)});
        return err;
    };
    try File.stdout().writeStreamingAll(init.io, "telar config: OK\n");
}

const ResolvedSelection = struct {
    path: []const u8,
    explicit: bool,
};

fn resolveSelection(environ: std.process.Environ, selection: Selection, path_buffer: []u8) !ResolvedSelection {
    if (selection.path) |value| {
        return .{ .path = std.mem.span(value), .explicit = true };
    }

    return .{
        .path = try frontend.config.defaultPath(environ, path_buffer),
        .explicit = selection.profile != null,
    };
}

test "an explicit config path takes precedence over the environment" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TELAR_DEVELOPMENT_CONFIG", "/environment/config.lua");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;

    const selected = try resolveSelection(.{ .block = block }, .{ .path = "/explicit/config.lua" }, &path_buffer);

    try std.testing.expect(selected.explicit);
    try std.testing.expectEqualStrings("/explicit/config.lua", selected.path);
}

test "a profile makes the default config path explicit" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", "/home/adrian");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;

    const selected = try resolveSelection(.{ .block = block }, .{ .profile = "work" }, &path_buffer);

    try std.testing.expect(selected.explicit);
    try std.testing.expectEqualStrings("/home/adrian/.config/telar/config.lua", selected.path);
}

test "an unqualified default config path remains optional" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("XDG_CONFIG_HOME", "/config");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;

    const selected = try resolveSelection(.{ .block = block }, .{}, &path_buffer);

    try std.testing.expect(!selected.explicit);
    try std.testing.expectEqualStrings("/config/telar/config.lua", selected.path);
}
