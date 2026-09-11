//! Compiler for `config.runtime.session`.

const lua_api = @import("lua-api");
const RuntimeSnapshotType = @import("RuntimeSnapshot.zig");
const DiagnosticType = @import("telar-client").Diagnostic;
const value = @import("lua_value.zig");
const config_model = @import("model.zig");
const std = @import("std");
const OptionalBoolean = @import("OptionalBoolean.zig");

pub fn parse(state: *lua_api.c.lua_State, runtime: *RuntimeSnapshotType, diagnostic: *DiagnosticType) !void {
    const absolute = lua_api.c.lua_absindex(state, -1);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.runtime.session must be a table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "persist", "path", "resume_agents" },
        .path = "config.runtime.session",
    }, diagnostic);

    runtime.session_resume_agents = try optionalBoolean(
        state,
        .{ .table = absolute, .field = "resume_agents", .default = runtime.session_resume_agents },
        diagnostic,
    );
    runtime.session_persist = try optionalBoolean(
        state,
        .{ .table = absolute, .field = "persist", .default = runtime.session_persist },
        diagnostic,
    );

    _ = lua_api.c.lua_getfield(state, absolute, "path");
    defer value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
        return;
    }

    const path = value.string(state, -1) orelse {
        diagnostic.set("config.runtime.session.path is invalid", .{});
        return error.InvalidConfig;
    };
    if (path.len == 0 or path.len > config_model.max_history_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) {
        diagnostic.set("config.runtime.session.path is invalid", .{});
        return error.InvalidConfig;
    }

    @memcpy(runtime.session_path_bytes[0..path.len], path);
    runtime.session_path_len = @intCast(path.len);
}

fn optionalBoolean(state: *lua_api.c.lua_State, input: OptionalBoolean, diagnostic: *DiagnosticType) !bool {
    _ = lua_api.c.lua_getfield(state, input.table, input.field);
    defer value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
        return input.default;
    }
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TBOOLEAN) {
        diagnostic.set("config.runtime.session.{s} must be a boolean", .{std.mem.span(input.field)});
        return error.InvalidConfig;
    }

    return lua_api.c.lua_toboolean(state, -1) != 0;
}
