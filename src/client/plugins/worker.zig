//! Isolated one-shot Lua plugin worker.

const std = @import("std");
const Input = @import("Input.zig");
const generation_support = @import("../config/generation_support.zig");
const DiagnosticType = @import("../config/Diagnostic.zig");
const GenerationType = @import("../config/Generation.zig");
const protocol = @import("protocol.zig");

/// Runs one validated plugin callback and writes its encoded effect batch.
/// For example: `try run(init, .{ .entry_path = entry, .action_name = action, .context = context });`.
pub fn run(init: std.process.Init, input: Input) !void {
    const entry_path = input.entry_path;
    const action_name = input.action_name;

    if (!validActionName(action_name)) {
        return error.InvalidPluginAction;
    }
    const entry = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        entry_path,
        init.gpa,
        .limited(generation_support.max_config_bytes),
    );
    defer init.gpa.free(entry);

    const wrapper = try init.gpa.alloc(u8, entry.len + action_name.len + 512);
    defer init.gpa.free(wrapper);
    var writer: std.Io.Writer = .fixed(wrapper);
    try writer.writeAll(
        \\local telar = require("telar")
        \\local plugin = (function()
        \\
    );
    try writer.writeAll(entry);
    try writer.writeAll(
        \\
        \\end)()
        \\if type(plugin) ~= "table" or type(plugin.actions) ~= "table" then
        \\  error("plugin must return a table with an actions table")
        \\end
        \\local callback = plugin.actions["
    );
    try writer.writeAll(action_name);
    try writer.writeAll(
        \\"] 
        \\if type(callback) ~= "function" then error("plugin action is not a function") end
        \\return { api_version = 2, client = { keybindings = {
        \\  telar.bind_global({ "escape" }, callback),
        \\} } }
    );

    var diagnostic: DiagnosticType = .{};
    const generation = GenerationType.loadSource(.{
        .gpa = init.gpa,
        .io = init.io,
        .diagnostic = &diagnostic,
    }, .{
        .source = writer.buffered(),
        .source_name = "@plugin-worker.lua",
        .config_dir = std.fs.path.dirname(entry_path) orelse ".",
        .number = 1,
    }) catch |err| {
        std.debug.print("plugin load failed: {s}\n", .{diagnostic.message()});
        return err;
    };
    defer generation.deinit();
    const reference = switch (generation.snapshot.bindings[0].action) {
        .lua_callback => |value| value,
        else => return error.InvalidPluginAction,
    };
    const batch = generation.invokeCallback(.{ .reference = reference, .context = input.context }, &diagnostic) catch |err| {
        std.debug.print("plugin action failed: {s}\n", .{diagnostic.message()});
        return err;
    };
    var encoded: [protocol.max_bytes]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(init.io, try protocol.encode(&encoded, &batch));
}

fn validActionName(value: []const u8) bool {
    if (value.len == 0) {
        return false;
    }
    for (value) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.')
            return false;
    return true;
}
