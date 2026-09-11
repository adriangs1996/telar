const GenerationType = @import("telar-frontend").Generation;
const CallbackRefType = @import("telar-client").InputCallbackRef;
const DiagnosticType = @import("telar-client").Diagnostic;
const std = @import("std");
const LuaCallbackContext = @This();

generation: *GenerationType,
reference: CallbackRefType,
diagnostic: DiagnosticType = .{},

pub fn init(gpa: std.mem.Allocator, io: std.Io) !LuaCallbackContext {
    var diagnostic: DiagnosticType = .{};
    const generation = try GenerationType.loadSource(.{ .gpa = gpa, .io = io, .diagnostic = &diagnostic }, .{
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
