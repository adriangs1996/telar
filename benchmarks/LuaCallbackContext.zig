const client = @import("telar-client");
const data = @import("model");
const std = @import("std");
const LuaCallbackContext = @This();

generation: *client.Generation,
reference: data.InputCallbackRef,
diagnostic: data.Diagnostic = .{},

pub fn init(gpa: std.mem.Allocator, io: std.Io) !LuaCallbackContext {
    var diagnostic: data.Diagnostic = .{};
    const generation = try client.Generation.loadSource(.{ .gpa = gpa, .io = io, .diagnostic = &diagnostic }, .{
        .source = "local t=require('telar'); return { api_version=2, client={ keybindings={ t.bind_global({'escape'}, function(ctx) return t.action.toggle_sidebar() end) } } }",
        .source_name = "@benchmark.lua",
        .number = 1,
    });
    return .{
        .generation = generation,
        .reference = generation.snapshot.bindings[0].action.lua_callback,
    };
}

pub fn deinit(context: *LuaCallbackContext) void {
    context.generation.deinit();
}
