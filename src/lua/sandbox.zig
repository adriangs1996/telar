//! Common Lua library allowlist for all Telar-owned VMs.

const std = @import("std");
const lua = @import("lua-api").c;
const Vm = @import("vm.zig").Vm;

/// Opens the restricted standard library set and removes unsafe base globals.
///
/// ```zig
/// try sandbox.open(state);
/// ```
pub fn open(state: *lua.lua_State) !void {
    openLibrary(state, "_G", lua.luaopen_base);
    openLibrary(state, lua.LUA_COLIBNAME, lua.luaopen_coroutine);
    openLibrary(state, lua.LUA_MATHLIBNAME, lua.luaopen_math);
    openLibrary(state, lua.LUA_STRLIBNAME, lua.luaopen_string);
    openLibrary(state, lua.LUA_TABLIBNAME, lua.luaopen_table);
    openLibrary(state, lua.LUA_UTF8LIBNAME, lua.luaopen_utf8);

    for ([_][*:0]const u8{
        "collectgarbage",
        "dofile",
        "getmetatable",
        "load",
        "loadfile",
        "print",
        "rawset",
        "setmetatable",
    }) |name| {
        lua.lua_pushnil(state);
        lua.lua_setglobal(state, name);
    }
}

fn openLibrary(state: *lua.lua_State, name: [*:0]const u8, function: lua.lua_CFunction) void {
    lua.luaL_requiref(state, name, function, 1);
    lua.lua_settop(state, -2);
}

test "sandbox does not expose filesystem or process libraries" {
    var vm = try Vm.init(std.testing.io, .{});
    defer vm.deinit();
    try open(vm.state);

    inline for (.{ "io", "os", "package" }) |name| {
        _ = lua.lua_getglobal(vm.state, name);
        try std.testing.expectEqual(lua.LUA_TNIL, lua.lua_type(vm.state, -1));
        lua.lua_settop(vm.state, -2);
    }
}
