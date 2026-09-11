const Host = @This();
const source_namespace = @import("host_support.zig");
const std = @import("std");
const lua_runtime = @import("telar-lua");
const lua = @import("lua-api").c;
const protocol = @import("protocol.zig");
const effects = @import("effects.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
vm: *lua_runtime.Vm,
package_root: []const u8,
callback_ref: c_int = lua.LUA_NOREF,
module_cache_ref: c_int = lua.LUA_NOREF,

fn init(init_process: std.process.Init, entry_path: []const u8) !Host {
    return initWithResources(init_process.io, init_process.gpa, entry_path);
}

pub fn initWithResources(io: source_namespace.Io, gpa: std.mem.Allocator, entry_path: []const u8) !Host {
    const root = std.fs.path.dirname(entry_path) orelse return error.InvalidEntrypoint;
    var host: Host = .{
        .io = io,
        .gpa = gpa,
        .vm = try lua_runtime.Vm.init(io, .{
            .memory = 64 * 1024 * 1024,
            .instructions = 5_000_000,
            .deadline_after_ns = 200 * std.time.ns_per_ms,
        }),
        .package_root = try gpa.dupe(u8, root),
    };
    errdefer host.deinit();
    try lua_runtime.sandbox.open(host.vm.state);
    try host.installTelar();
    host.installRequire();
    try host.loadPlugin(entry_path);
    return host;
}

pub fn deinit(host: *Host) void {
    host.vm.deinit();
    host.gpa.free(host.package_root);
}

fn installTelar(host: *Host) !void {
    try host.vm.evaluate(@embedFile("bootstrap.lua"), "@telar-tap-bootstrap.lua");
    const state = host.vm.state;
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
        return error.InvalidBootstrap;
    }
    lua.lua_pushvalue(state, -1);
    lua.lua_setglobal(state, "telar");

    _ = lua.lua_getfield(state, -1, "redact");
    lua.lua_pushlightuserdata(state, host);
    lua.lua_pushcclosure(state, source_namespace.redactSecrets, 1);
    lua.lua_setfield(state, -2, "secrets");
    source_namespace.pop(state, 1);

    _ = lua.lua_getfield(state, -1, "json");
    lua.lua_pushlightuserdata(state, host);
    lua.lua_pushcclosure(state, source_namespace.decodeJson, 1);
    lua.lua_setfield(state, -2, "decode");
    lua.lua_settop(state, 0);
}

fn installRequire(host: *Host) void {
    const state = host.vm.state;
    lua.lua_createtable(state, 0, 16);
    host.module_cache_ref = lua.luaL_ref(state, lua.LUA_REGISTRYINDEX);
    lua.lua_pushlightuserdata(state, host);
    lua.lua_pushcclosure(state, source_namespace.requireLocal, 1);
    lua.lua_setglobal(state, "require");
}

fn loadPlugin(host: *Host, entry_path: []const u8) !void {
    const source = try source_namespace.Io.Dir.cwd().readFileAlloc(host.io, entry_path, host.gpa, .limited(source_namespace.max_entry_bytes));
    defer host.gpa.free(source);
    host.vm.resetBudget(5_000_000, 200 * std.time.ns_per_ms);
    try host.vm.evaluate(source, "@tap-plugin.lua");
    const state = host.vm.state;
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
        return error.InvalidTapPlugin;
    }
    _ = lua.lua_getfield(state, -1, "on_exchange");
    if (lua.lua_type(state, -1) != lua.LUA_TFUNCTION) {
        return error.MissingExchangeHandler;
    }
    host.callback_ref = lua.luaL_ref(state, lua.LUA_REGISTRYINDEX);
    lua.lua_settop(state, 0);
}

pub fn invoke(host: *Host, exchange: protocol.Exchange) !effects.Batch {
    const state = host.vm.state;
    lua.lua_settop(state, 0);
    defer lua.lua_settop(state, 0);
    host.vm.resetBudget(5_000_000, 200 * std.time.ns_per_ms);
    _ = lua.lua_rawgeti(state, lua.LUA_REGISTRYINDEX, host.callback_ref);
    source_namespace.pushExchange(state, exchange);
    if (lua.lua_pcallk(state, 1, 1, 0, 0, null) != lua.LUA_OK) {
        return error.TapCallbackFailed;
    }
    return source_namespace.parseEffects(state, -1);
}
