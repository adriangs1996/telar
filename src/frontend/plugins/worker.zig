//! Isolated one-shot Lua plugin worker.

const std = @import("std");
const lua_config = @import("../config/root.zig");
const protocol = @import("protocol.zig");

const Io = std.Io;

pub fn run(
    init: std.process.Init,
    entry_path: []const u8,
    action_name: []const u8,
    context: lua_config.CallbackContext,
) !void {
    if (!validActionName(action_name)) return error.InvalidPluginAction;
    const entry = try Io.Dir.cwd().readFileAlloc(
        init.io,
        entry_path,
        init.gpa,
        .limited(lua_config.max_config_bytes),
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

    var diagnostic: lua_config.Diagnostic = .{};
    const generation = lua_config.Generation.loadSourceAt(
        init.gpa,
        init.io,
        writer.buffered(),
        "@plugin-worker.lua",
        std.fs.path.dirname(entry_path) orelse ".",
        1,
        &diagnostic,
    ) catch |err| {
        std.debug.print("plugin load failed: {s}\n", .{diagnostic.message()});
        return err;
    };
    defer generation.deinit();
    const reference = switch (generation.snapshot.bindings[0].action) {
        .lua_callback => |value| value,
        else => return error.InvalidPluginAction,
    };
    const batch = generation.invokeCallback(reference, context, &diagnostic) catch |err| {
        std.debug.print("plugin action failed: {s}\n", .{diagnostic.message()});
        return err;
    };
    var encoded: [protocol.max_bytes]u8 = undefined;
    try Io.File.stdout().writeStreamingAll(init.io, try protocol.encode(&encoded, &batch));
}

fn validActionName(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.')
            return false;
    return true;
}
