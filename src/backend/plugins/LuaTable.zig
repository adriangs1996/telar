const lua_api = @import("lua-api");
const host_support = @import("host_support.zig");
const LuaTable = @This();

state: *lua_api.c.lua_State,
index: c_int,

pub fn init(state: *lua_api.c.lua_State, index: c_int) LuaTable {
    return .{ .state = state, .index = lua_api.c.lua_absindex(state, index) };
}

pub fn string(table: LuaTable, name: [*:0]const u8, required: bool) ![]const u8 {
    _ = lua_api.c.lua_getfield(table.state, table.index, name);
    defer host_support.pop(table.state, 1);
    if (!required and lua_api.c.lua_type(table.state, -1) == lua_api.c.LUA_TNIL) {
        return "";
    }

    return host_support.luaString(table.state, -1) orelse error.InvalidEffect;
}

pub fn optionalString(table: LuaTable, name: [*:0]const u8) !?[]const u8 {
    _ = lua_api.c.lua_getfield(table.state, table.index, name);
    defer host_support.pop(table.state, 1);
    if (lua_api.c.lua_type(table.state, -1) == lua_api.c.LUA_TNIL) {
        return null;
    }

    return host_support.luaString(table.state, -1) orelse error.InvalidEffect;
}

pub fn integer(table: LuaTable, name: [*:0]const u8, default: i64) !i64 {
    _ = lua_api.c.lua_getfield(table.state, table.index, name);
    defer host_support.pop(table.state, 1);
    if (lua_api.c.lua_type(table.state, -1) == lua_api.c.LUA_TNIL) {
        return default;
    }

    var valid: c_int = 0;
    const value = lua_api.c.lua_tointegerx(table.state, -1, &valid);

    return if (valid != 0) value else error.InvalidEffect;
}

pub fn boolean(table: LuaTable, name: [*:0]const u8, default: bool) !bool {
    _ = lua_api.c.lua_getfield(table.state, table.index, name);
    defer host_support.pop(table.state, 1);
    if (lua_api.c.lua_type(table.state, -1) == lua_api.c.LUA_TNIL) {
        return default;
    }

    if (lua_api.c.lua_type(table.state, -1) != lua_api.c.LUA_TBOOLEAN) {
        return error.InvalidEffect;
    }

    return lua_api.c.lua_toboolean(table.state, -1) != 0;
}

pub fn setString(table: LuaTable, name: [*:0]const u8, value: []const u8) void {
    _ = lua_api.c.lua_pushlstring(table.state, value.ptr, value.len);
    lua_api.c.lua_setfield(table.state, table.index, name);
}

pub fn setInteger(table: LuaTable, name: [*:0]const u8, value: anytype) void {
    lua_api.c.lua_pushinteger(table.state, @intCast(value));
    lua_api.c.lua_setfield(table.state, table.index, name);
}

pub fn setBoolean(table: LuaTable, name: [*:0]const u8, value: bool) void {
    lua_api.c.lua_pushboolean(table.state, @intFromBool(value));
    lua_api.c.lua_setfield(table.state, table.index, name);
}
