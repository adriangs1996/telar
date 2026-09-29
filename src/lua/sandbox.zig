//! Common Lua library allowlist for all Telar-owned VMs.

const lua_api = @import("lua-api");
const Vm = @import("Vm.zig");
const std = @import("std");

/// Opens the restricted standard library set and removes unsafe base globals.
///
/// ```zig
/// try sandbox.open(state);
/// ```
pub fn open(state: *lua_api.c.lua_State) !void {
    openLibrary(state, "_G", lua_api.c.luaopen_base);
    openLibrary(state, lua_api.c.LUA_COLIBNAME, lua_api.c.luaopen_coroutine);
    openLibrary(state, lua_api.c.LUA_MATHLIBNAME, lua_api.c.luaopen_math);
    openLibrary(state, lua_api.c.LUA_STRLIBNAME, lua_api.c.luaopen_string);
    openLibrary(state, lua_api.c.LUA_TABLIBNAME, lua_api.c.luaopen_table);
    openLibrary(state, lua_api.c.LUA_UTF8LIBNAME, lua_api.c.luaopen_utf8);

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
        lua_api.c.lua_pushnil(state);
        lua_api.c.lua_setglobal(state, name);
    }
}

fn openLibrary(state: *lua_api.c.lua_State, name: [*:0]const u8, function: lua_api.c.lua_CFunction) void {
    lua_api.c.luaL_requiref(state, name, function, 1);
    lua_api.c.lua_settop(state, -2);
}

test "sandbox does not expose filesystem or process libraries" {
    var vm = try Vm.init(std.testing.io, std.testing.allocator, .{});
    defer vm.deinit();
    try open(vm.state);

    inline for (.{ "io", "os", "package" }) |name| {
        _ = lua_api.c.lua_getglobal(vm.state, name);
        try std.testing.expectEqual(lua_api.c.LUA_TNIL, lua_api.c.lua_type(vm.state, -1));
        lua_api.c.lua_settop(vm.state, -2);
    }
}

test "the wall-clock safety net interrupts instructions the count does not see" {
    var vm = try Vm.init(std.testing.io, std.testing.allocator, .{
        .memory = 32 * 1024 * 1024,
        .instructions = std.math.maxInt(u64),
        .deadline_after_ns = 50 * std.time.ns_per_ms,
    });
    defer vm.deinit();

    try open(vm.state);
    try std.testing.expectError(error.LuaRuntimeFailed, vm.evaluate("while true do local s = string.rep('x', 1 << 18) end", "@slow.lua"));
    try std.testing.expect(std.mem.indexOf(u8, vm.errorMessage(), "budget exceeded") != null);
}
