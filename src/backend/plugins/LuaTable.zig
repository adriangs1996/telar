const LuaTable = @This();
const lua = @import("lua-api").c;
const source_namespace = @import("host_support.zig");
state: *lua.lua_State,
index: c_int,

pub fn init(state: *lua.lua_State, index: c_int) LuaTable {
    return .{ .state = state, .index = lua.lua_absindex(state, index) };
}

pub fn string(table: LuaTable, name: [*:0]const u8, required: bool) ![]const u8 {
    _ = lua.lua_getfield(table.state, table.index, name);
    defer source_namespace.pop(table.state, 1);
    if (!required and lua.lua_type(table.state, -1) == lua.LUA_TNIL) {
        return "";
    }

    return source_namespace.luaString(table.state, -1) orelse error.InvalidEffect;
}

pub fn optionalString(table: LuaTable, name: [*:0]const u8) !?[]const u8 {
    _ = lua.lua_getfield(table.state, table.index, name);
    defer source_namespace.pop(table.state, 1);
    if (lua.lua_type(table.state, -1) == lua.LUA_TNIL) {
        return null;
    }

    return source_namespace.luaString(table.state, -1) orelse error.InvalidEffect;
}

pub fn integer(table: LuaTable, name: [*:0]const u8, default: i64) !i64 {
    _ = lua.lua_getfield(table.state, table.index, name);
    defer source_namespace.pop(table.state, 1);
    if (lua.lua_type(table.state, -1) == lua.LUA_TNIL) {
        return default;
    }

    var valid: c_int = 0;
    const value = lua.lua_tointegerx(table.state, -1, &valid);

    return if (valid != 0) value else error.InvalidEffect;
}

pub fn boolean(table: LuaTable, name: [*:0]const u8, default: bool) !bool {
    _ = lua.lua_getfield(table.state, table.index, name);
    defer source_namespace.pop(table.state, 1);
    if (lua.lua_type(table.state, -1) == lua.LUA_TNIL) {
        return default;
    }

    if (lua.lua_type(table.state, -1) != lua.LUA_TBOOLEAN) {
        return error.InvalidEffect;
    }

    return lua.lua_toboolean(table.state, -1) != 0;
}

pub fn setString(table: LuaTable, name: [*:0]const u8, value: []const u8) void {
    _ = lua.lua_pushlstring(table.state, value.ptr, value.len);
    lua.lua_setfield(table.state, table.index, name);
}

pub fn setInteger(table: LuaTable, name: [*:0]const u8, value: anytype) void {
    lua.lua_pushinteger(table.state, @intCast(value));
    lua.lua_setfield(table.state, table.index, name);
}

pub fn setBoolean(table: LuaTable, name: [*:0]const u8, value: bool) void {
    lua.lua_pushboolean(table.state, @intFromBool(value));
    lua.lua_setfield(table.state, table.index, name);
}
