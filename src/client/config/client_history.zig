//! Compiler for client history presentation and activation behavior.

const data = @import("model");
const lua_api = @import("lua-api");
const Snapshot = @import("Snapshot.zig");
const value = @import("lua_value.zig");
const std = @import("std");

pub fn parse(state: *lua_api.c.lua_State, snapshot: *Snapshot, diagnostic: *data.Diagnostic) !void {
    const absolute = lua_api.c.lua_absindex(state, -1);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.history must be a table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "show_agent_commands", "enter", "match" },
        .path = "config.client.history",
    }, diagnostic);
    var parser: ClientHistoryParser = .{ .state = state, .snapshot = snapshot, .diagnostic = diagnostic };
    try parser.parseMatch(absolute);
    try parser.parseVisibility(absolute);
    try parser.parseEnter(absolute);
}

const ClientHistoryParser = struct {
    state: *lua_api.c.lua_State,
    snapshot: *Snapshot,
    diagnostic: *data.Diagnostic,

    pub fn parseMatch(self: *ClientHistoryParser, absolute: c_int) !void {
        _ = lua_api.c.lua_getfield(self.state, absolute, "match");
        defer value.pop(self.state, 1);
        if (lua_api.c.lua_type(self.state, -1) == lua_api.c.LUA_TNIL) {
            return;
        }

        const mode = value.string(self.state, -1) orelse {
            self.diagnostic.set("config.client.history.match must be fuzzy or fts", .{});
            return error.InvalidConfig;
        };
        if (std.mem.eql(u8, mode, "fts")) {
            self.snapshot.history_match_fts = true;
        } else if (std.mem.eql(u8, mode, "fuzzy")) {
            self.snapshot.history_match_fts = false;
        } else {
            self.diagnostic.set("config.client.history.match must be fuzzy or fts", .{});
            return error.InvalidConfig;
        }
    }

    pub fn parseVisibility(self: *ClientHistoryParser, absolute: c_int) !void {
        _ = lua_api.c.lua_getfield(self.state, absolute, "show_agent_commands");
        defer value.pop(self.state, 1);
        if (lua_api.c.lua_type(self.state, -1) == lua_api.c.LUA_TNIL) {
            return;
        }
        if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TBOOLEAN) {
            self.diagnostic.set("config.client.history.show_agent_commands must be a boolean", .{});
            return error.InvalidConfig;
        }

        self.snapshot.history_show_agent_commands = lua_api.c.lua_toboolean(self.state, -1) != 0;
    }

    pub fn parseEnter(self: *ClientHistoryParser, absolute: c_int) !void {
        _ = lua_api.c.lua_getfield(self.state, absolute, "enter");
        defer value.pop(self.state, 1);
        if (lua_api.c.lua_type(self.state, -1) == lua_api.c.LUA_TNIL) {
            return;
        }

        const mode = value.string(self.state, -1) orelse {
            self.diagnostic.set("config.client.history.enter must be paste or run", .{});
            return error.InvalidConfig;
        };
        if (std.mem.eql(u8, mode, "run")) {
            self.snapshot.history_enter_runs = true;
        } else if (std.mem.eql(u8, mode, "paste")) {
            self.snapshot.history_enter_runs = false;
        } else {
            self.diagnostic.set("config.client.history.enter must be paste or run", .{});
            return error.InvalidConfig;
        }
    }
};
