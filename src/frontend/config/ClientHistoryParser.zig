const lua_api = @import("lua-api");
const SnapshotType = @import("Snapshot.zig");
const DiagnosticType = @import("telar-client").Diagnostic;
const value = @import("lua_value.zig");
const std = @import("std");
const Parser = @This();

state: *lua_api.c.lua_State,
snapshot: *SnapshotType,
diagnostic: *DiagnosticType,

pub fn parseMatch(parser: *Parser, absolute: c_int) !void {
    _ = lua_api.c.lua_getfield(parser.state, absolute, "match");
    defer value.pop(parser.state, 1);
    if (lua_api.c.lua_type(parser.state, -1) == lua_api.c.LUA_TNIL) {
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

pub fn parseVisibility(parser: *Parser, absolute: c_int) !void {
    _ = lua_api.c.lua_getfield(parser.state, absolute, "show_agent_commands");
    defer value.pop(parser.state, 1);
    if (lua_api.c.lua_type(parser.state, -1) == lua_api.c.LUA_TNIL) {
        return;
    }
    if (lua_api.c.lua_type(parser.state, -1) != lua_api.c.LUA_TBOOLEAN) {
        parser.diagnostic.set("config.client.history.show_agent_commands must be a boolean", .{});
        return error.InvalidConfig;
    }

    parser.snapshot.history_show_agent_commands = lua_api.c.lua_toboolean(parser.state, -1) != 0;
}

pub fn parseEnter(parser: *Parser, absolute: c_int) !void {
    _ = lua_api.c.lua_getfield(parser.state, absolute, "enter");
    defer value.pop(parser.state, 1);
    if (lua_api.c.lua_type(parser.state, -1) == lua_api.c.LUA_TNIL) {
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
