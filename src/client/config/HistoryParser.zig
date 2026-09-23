const data = @import("model");
const lua_api = @import("lua-api");
const RuntimeSnapshot = @import("RuntimeSnapshot.zig");
const value = @import("lua_value.zig");
const std = @import("std");
const history = @import("history.zig");
const Parser = @This();

state: *lua_api.c.lua_State,
runtime: *RuntimeSnapshot,
diagnostic: *data.Diagnostic,

pub fn parseOutput(self: *Parser, absolute: c_int) !void {
    _ = lua_api.c.lua_getfield(self.state, absolute, "output");
    defer value.pop(self.state, 1);
    if (lua_api.c.lua_type(self.state, -1) == lua_api.c.LUA_TNIL) {
        return;
    }

    const mode = value.string(self.state, -1) orelse {
        self.diagnostic.set("config.runtime.history.output must be off or bounded", .{});
        return error.InvalidConfig;
    };
    if (std.mem.eql(u8, mode, "bounded")) {
        self.runtime.history_output_capture = true;
        return;
    }
    if (std.mem.eql(u8, mode, "off")) {
        self.runtime.history_output_capture = false;
        return;
    }

    self.diagnostic.set("config.runtime.history.output must be off or bounded", .{});
    return error.InvalidConfig;
}

pub fn parsePath(self: *Parser, absolute: c_int) !void {
    _ = lua_api.c.lua_getfield(self.state, absolute, "path");
    defer value.pop(self.state, 1);
    if (lua_api.c.lua_type(self.state, -1) == lua_api.c.LUA_TNIL) {
        return;
    }

    const path = value.string(self.state, -1) orelse {
        self.diagnostic.set("config.runtime.history.path must be a string", .{});
        return error.InvalidConfig;
    };
    if (path.len == 0 or path.len > data.config_values.max_history_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) {
        self.diagnostic.set("config.runtime.history.path is invalid", .{});
        return error.InvalidConfig;
    }

    @memcpy(self.runtime.history_path_bytes[0..path.len], path);
    self.runtime.history_path_len = @intCast(path.len);
}

pub fn parseSecretsFilter(self: *Parser, absolute: c_int) !void {
    _ = lua_api.c.lua_getfield(self.state, absolute, "secrets_filter");
    defer value.pop(self.state, 1);
    if (lua_api.c.lua_type(self.state, -1) == lua_api.c.LUA_TNIL) {
        return;
    }
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TBOOLEAN) {
        self.diagnostic.set("config.runtime.history.secrets_filter must be a boolean", .{});
        return error.InvalidConfig;
    }

    self.runtime.history_filters.secrets = lua_api.c.lua_toboolean(self.state, -1) != 0;
}

pub fn parsePatterns(self: *Parser, absolute: c_int, kind: history.PatternKind) !void {
    const name: [:0]const u8 = switch (kind) {
        .commands => "command_filters",
        .cwds => "cwd_filters",
    };
    _ = lua_api.c.lua_getfield(self.state, absolute, name.ptr);
    defer value.pop(self.state, 1);
    if (lua_api.c.lua_type(self.state, -1) == lua_api.c.LUA_TNIL) {
        return;
    }
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TTABLE) {
        self.diagnostic.set("config.runtime.history.{s} must be an array of strings", .{name});
        return error.InvalidConfig;
    }

    const table = lua_api.c.lua_absindex(self.state, -1);
    const count = lua_api.c.lua_rawlen(self.state, table);
    try value.ensureArrayOnly(self.state, .{
        .index = table,
        .count = count,
        .path = switch (kind) {
            .commands => "config.runtime.history.command_filters",
            .cwds => "config.runtime.history.cwd_filters",
        },
    }, self.diagnostic);
    const list = switch (kind) {
        .commands => &self.runtime.history_filters.commands,
        .cwds => &self.runtime.history_filters.cwds,
    };
    for (1..count + 1) |item| {
        _ = lua_api.c.lua_rawgeti(self.state, table, @intCast(item));
        defer value.pop(self.state, 1);
        const pattern = value.string(self.state, -1) orelse {
            self.diagnostic.set("config.runtime.history.{s}[{d}] must be a string", .{ name, item });
            return error.InvalidConfig;
        };
        list.add(pattern) catch {
            self.diagnostic.set("config.runtime.history.{s}[{d}] is empty, too long or exceeds the pattern limit", .{ name, item });
            return error.InvalidConfig;
        };
    }
}
