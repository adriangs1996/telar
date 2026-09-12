const lua_api = @import("lua-api");
const RuntimeSnapshotType = @import("RuntimeSnapshot.zig");
const DiagnosticType = @import("Diagnostic.zig");
const value = @import("lua_value.zig");
const std = @import("std");
const config_model = @import("model.zig");
const history = @import("history.zig");
const Parser = @This();

state: *lua_api.c.lua_State,
runtime: *RuntimeSnapshotType,
diagnostic: *DiagnosticType,

pub fn parseOutput(parser: *Parser, absolute: c_int) !void {
    _ = lua_api.c.lua_getfield(parser.state, absolute, "output");
    defer value.pop(parser.state, 1);
    if (lua_api.c.lua_type(parser.state, -1) == lua_api.c.LUA_TNIL) {
        return;
    }

    const mode = value.string(parser.state, -1) orelse {
        parser.diagnostic.set("config.runtime.history.output must be off or bounded", .{});
        return error.InvalidConfig;
    };
    if (std.mem.eql(u8, mode, "bounded")) {
        parser.runtime.history_output_capture = true;
        return;
    }
    if (std.mem.eql(u8, mode, "off")) {
        parser.runtime.history_output_capture = false;
        return;
    }

    parser.diagnostic.set("config.runtime.history.output must be off or bounded", .{});
    return error.InvalidConfig;
}

pub fn parsePath(parser: *Parser, absolute: c_int) !void {
    _ = lua_api.c.lua_getfield(parser.state, absolute, "path");
    defer value.pop(parser.state, 1);
    if (lua_api.c.lua_type(parser.state, -1) == lua_api.c.LUA_TNIL) {
        return;
    }

    const path = value.string(parser.state, -1) orelse {
        parser.diagnostic.set("config.runtime.history.path must be a string", .{});
        return error.InvalidConfig;
    };
    if (path.len == 0 or path.len > config_model.max_history_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) {
        parser.diagnostic.set("config.runtime.history.path is invalid", .{});
        return error.InvalidConfig;
    }

    @memcpy(parser.runtime.history_path_bytes[0..path.len], path);
    parser.runtime.history_path_len = @intCast(path.len);
}

pub fn parseSecretsFilter(parser: *Parser, absolute: c_int) !void {
    _ = lua_api.c.lua_getfield(parser.state, absolute, "secrets_filter");
    defer value.pop(parser.state, 1);
    if (lua_api.c.lua_type(parser.state, -1) == lua_api.c.LUA_TNIL) {
        return;
    }
    if (lua_api.c.lua_type(parser.state, -1) != lua_api.c.LUA_TBOOLEAN) {
        parser.diagnostic.set("config.runtime.history.secrets_filter must be a boolean", .{});
        return error.InvalidConfig;
    }

    parser.runtime.history_filters.secrets = lua_api.c.lua_toboolean(parser.state, -1) != 0;
}

pub fn parsePatterns(parser: *Parser, absolute: c_int, kind: history.PatternKind) !void {
    const name: [:0]const u8 = switch (kind) {
        .commands => "command_filters",
        .cwds => "cwd_filters",
    };
    _ = lua_api.c.lua_getfield(parser.state, absolute, name.ptr);
    defer value.pop(parser.state, 1);
    if (lua_api.c.lua_type(parser.state, -1) == lua_api.c.LUA_TNIL) {
        return;
    }
    if (lua_api.c.lua_type(parser.state, -1) != lua_api.c.LUA_TTABLE) {
        parser.diagnostic.set("config.runtime.history.{s} must be an array of strings", .{name});
        return error.InvalidConfig;
    }

    const table = lua_api.c.lua_absindex(parser.state, -1);
    const count = lua_api.c.lua_rawlen(parser.state, table);
    try value.ensureArrayOnly(parser.state, .{
        .index = table,
        .count = count,
        .path = switch (kind) {
            .commands => "config.runtime.history.command_filters",
            .cwds => "config.runtime.history.cwd_filters",
        },
    }, parser.diagnostic);
    const list = switch (kind) {
        .commands => &parser.runtime.history_filters.commands,
        .cwds => &parser.runtime.history_filters.cwds,
    };
    for (1..count + 1) |item| {
        _ = lua_api.c.lua_rawgeti(parser.state, table, @intCast(item));
        defer value.pop(parser.state, 1);
        const pattern = value.string(parser.state, -1) orelse {
            parser.diagnostic.set("config.runtime.history.{s}[{d}] must be a string", .{ name, item });
            return error.InvalidConfig;
        };
        list.add(pattern) catch {
            parser.diagnostic.set("config.runtime.history.{s}[{d}] is empty, too long or exceeds the pattern limit", .{ name, item });
            return error.InvalidConfig;
        };
    }
}
