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

const Parser = struct {
    state: *lua.lua_State,
    snapshot: *config_model.Snapshot,
    diagnostic: *config_model.Diagnostic,

    fn parseMatch(parser: *Parser, absolute: c_int) !void {
        _ = lua.lua_getfield(parser.state, absolute, "match");
        defer value.pop(parser.state, 1);
        if (lua.lua_type(parser.state, -1) == lua.LUA_TNIL) {
            return;
        }

        const mode = value.string(parser.state, -1) orelse {
            parser.diagnostic.set("config.client.history.match must be fuzzy or fts", .{});
            return error.InvalidConfig;
        };
        if (std.mem.eql(u8, mode, "fts")) {
            parser.snapshot.history_match_fts = true;
        } else if (std.mem.eql(u8, mode, "fuzzy")) {
            parser.snapshot.history_match_fts = false;
        } else {
            parser.diagnostic.set("config.client.history.match must be fuzzy or fts", .{});
            return error.InvalidConfig;
        }
    }

    fn parseVisibility(parser: *Parser, absolute: c_int) !void {
        _ = lua.lua_getfield(parser.state, absolute, "show_agent_commands");
        defer value.pop(parser.state, 1);
        if (lua.lua_type(parser.state, -1) == lua.LUA_TNIL) {
            return;
        }
        if (lua.lua_type(parser.state, -1) != lua.LUA_TBOOLEAN) {
            parser.diagnostic.set("config.client.history.show_agent_commands must be a boolean", .{});
            return error.InvalidConfig;
        }

        parser.snapshot.history_show_agent_commands = lua.lua_toboolean(parser.state, -1) != 0;
    }

    fn parseEnter(parser: *Parser, absolute: c_int) !void {
        _ = lua.lua_getfield(parser.state, absolute, "enter");
        defer value.pop(parser.state, 1);
        if (lua.lua_type(parser.state, -1) == lua.LUA_TNIL) {
            return;
        }

        const mode = value.string(parser.state, -1) orelse {
            parser.diagnostic.set("config.client.history.enter must be paste or run", .{});
            return error.InvalidConfig;
        };
        if (std.mem.eql(u8, mode, "run")) {
            parser.snapshot.history_enter_runs = true;
        } else if (std.mem.eql(u8, mode, "paste")) {
            parser.snapshot.history_enter_runs = false;
        } else {
            parser.diagnostic.set("config.client.history.enter must be paste or run", .{});
            return error.InvalidConfig;
        }
    }
};
