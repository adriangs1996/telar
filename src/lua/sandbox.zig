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

test "one backtracking pattern search stops at the instruction budget" {
    var vm = try Vm.init(std.testing.io, std.testing.allocator, .{
        .instructions = 1_000_000,
        .deadline_after_ns = 3600 * std.time.ns_per_s,
    });
    defer vm.deinit();

    try open(vm.state);
    const source = "local n = 18 return string.find(string.rep('a', n), string.rep('a*', n) .. 'b')";
    try std.testing.expectError(error.LuaRuntimeFailed, vm.evaluate(source, "@backtrack.lua"));
    try std.testing.expect(std.mem.indexOf(u8, vm.errorMessage(), "budget exceeded") != null);
}

test "one long plain search stops at the instruction budget" {
    var vm = try Vm.init(std.testing.io, std.testing.allocator, .{
        .instructions = 1_000_000,
        .deadline_after_ns = 3600 * std.time.ns_per_s,
    });
    defer vm.deinit();

    try open(vm.state);
    const source = "local s = string.rep('a', 1 << 22) return s:find(string.rep('a', 1 << 21) .. 'b', 1, true)";
    try std.testing.expectError(error.LuaRuntimeFailed, vm.evaluate(source, "@plain.lua"));
    try std.testing.expect(std.mem.indexOf(u8, vm.errorMessage(), "budget exceeded") != null);
}

test "one back-reference comparison charges the bytes it compares" {
    var vm = try Vm.init(std.testing.io, std.testing.allocator, .{
        .instructions = 1_000_000,
        .deadline_after_ns = 3600 * std.time.ns_per_s,
    });
    defer vm.deinit();

    try open(vm.state);
    const source = "return string.rep('a', 4 << 20):find('^(a-)%1b')";
    try std.testing.expectError(error.LuaRuntimeFailed, vm.evaluate(source, "@capture.lua"));
    try std.testing.expect(std.mem.indexOf(u8, vm.errorMessage(), "budget exceeded") != null);
}

test "one sort of a large table stops at the instruction budget" {
    var vm = try Vm.init(std.testing.io, std.testing.allocator, .{
        .instructions = 5_000_000,
        .deadline_after_ns = 3600 * std.time.ns_per_s,
    });
    defer vm.deinit();

    try open(vm.state);
    const source = "local t = {} for i = 1, 600000 do t[i] = i * 7919 % 600000 end table.sort(t)";
    try std.testing.expectError(error.LuaRuntimeFailed, vm.evaluate(source, "@sort.lua"));
    try std.testing.expect(std.mem.indexOf(u8, vm.errorMessage(), "budget exceeded") != null);
}

test "pattern searches within the budget still answer" {
    var vm = try Vm.init(std.testing.io, std.testing.allocator, .{});
    defer vm.deinit();

    try open(vm.state);
    try vm.evaluate("local s = string.rep('word ', 4000) local _, n = s:gsub('%s+', ' ') return n", "@gsub.lua");
    try std.testing.expectEqual(@as(lua_api.c.lua_Integer, 4000), lua_api.c.lua_tointegerx(vm.state, -1, null));
}

test "a sort within the budget still sorts" {
    var vm = try Vm.init(std.testing.io, std.testing.allocator, .{});
    defer vm.deinit();

    try open(vm.state);
    try vm.evaluate("local t = {} for i = 1, 5000 do t[i] = i * 7919 % 5000 end table.sort(t) return t[1] + t[5000]", "@sorted.lua");
    try std.testing.expectEqual(@as(lua_api.c.lua_Integer, 4999), lua_api.c.lua_tointegerx(vm.state, -1, null));
}
