const LuaCallbackContext = @This();
const frontend = @import("telar-frontend");
const std = @import("std");
const source_namespace = @import("main.zig");
generation: *frontend.config.Generation,
reference: frontend.action.CallbackRef,
diagnostic: frontend.config.Diagnostic = .{},

fn init(gpa: std.mem.Allocator, io: source_namespace.Io) !LuaCallbackContext {
    var diagnostic: frontend.config.Diagnostic = .{};
    const generation = try frontend.config.Generation.loadSource(.{ .gpa = gpa, .io = io, .diagnostic = &diagnostic }, .{
        .source = "local t=require('telar'); return { api_version=2, client={ keybindings={ t.bind_global({'escape'}, function(ctx) return t.action.toggle_sidebar() end) } } }",
        .source_name = "@benchmark.lua",
        .number = 1,
    });
    return .{
        .generation = generation,
        .reference = generation.snapshot.bindings[0].action.lua_callback,
    };
}

fn deinit(context: *LuaCallbackContext) void {
    context.generation.deinit();
}
