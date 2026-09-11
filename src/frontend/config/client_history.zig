//! Compiler for client history presentation and activation behavior.

const std = @import("std");
const lua = @import("lua-api").c;
const config_model = @import("model.zig");
const value = @import("lua_value.zig");

pub fn parse(state: *lua.lua_State, snapshot: *config_model.Snapshot, diagnostic: *config_model.Diagnostic) !void {
    const absolute = lua.lua_absindex(state, -1);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.client.history must be a table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "show_agent_commands", "enter", "match" },
        .path = "config.client.history",
    }, diagnostic);
    var parser: Parser = .{ .state = state, .snapshot = snapshot, .diagnostic = diagnostic };
    try parser.parseMatch(absolute);
    try parser.parseVisibility(absolute);
    try parser.parseEnter(absolute);
}

const Parser = @import("ClientHistoryParser.zig");
