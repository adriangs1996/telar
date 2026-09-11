//! Compiler for bounded runtime history configuration.

const std = @import("std");
const lua = @import("lua-api").c;
const config_model = @import("model.zig");
const value = @import("lua_value.zig");

pub fn parse(state: *lua.lua_State, runtime: *config_model.RuntimeSnapshot, diagnostic: *config_model.Diagnostic) !void {
    const absolute = lua.lua_absindex(state, -1);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.runtime.history must be a table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "path", "secrets_filter", "command_filters", "cwd_filters", "output" },
        .path = "config.runtime.history",
    }, diagnostic);

    var parser: Parser = .{ .state = state, .runtime = runtime, .diagnostic = diagnostic };
    try parser.parseOutput(absolute);
    try parser.parsePath(absolute);
    try parser.parseSecretsFilter(absolute);
    try parser.parsePatterns(absolute, .commands);
    try parser.parsePatterns(absolute, .cwds);
}

const Parser = @import("HistoryParser.zig");

pub const PatternKind = enum {
    commands,
    cwds,
};
