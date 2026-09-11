const std = @import("std");
const VmType = @import("telar-lua").Vm;
const lua_api = @import("lua-api");
const open_module = @import("telar-lua").open;
const host_support = @import("host_support.zig");
const ExchangeType = @import("Exchange.zig");
const BatchType = @import("Batch.zig");
const Host = @This();

io: std.Io,
gpa: std.mem.Allocator,
vm: *VmType,
package_root: []const u8,
callback_ref: c_int = lua_api.c.LUA_NOREF,
module_cache_ref: c_int = lua_api.c.LUA_NOREF,

pub fn init(init_process: std.process.Init, entry_path: []const u8) !Host {
    return initWithResources(init_process.io, init_process.gpa, entry_path);
}

pub fn initWithResources(io: std.Io, gpa: std.mem.Allocator, entry_path: []const u8) !Host {
    const root = std.fs.path.dirname(entry_path) orelse return error.InvalidEntrypoint;
    var host: Host = .{
        .io = io,
        .gpa = gpa,
        .vm = try VmType.init(io, .{
            .memory = 64 * 1024 * 1024,
            .instructions = 5_000_000,
            .deadline_after_ns = 200 * std.time.ns_per_ms,
        }),
        .package_root = try gpa.dupe(u8, root),
    };
    errdefer host.deinit();
    try open_module(host.vm.state);
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
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        return error.InvalidBootstrap;
    }
    lua_api.c.lua_pushvalue(state, -1);
    lua_api.c.lua_setglobal(state, "telar");

    _ = lua_api.c.lua_getfield(state, -1, "redact");
    lua_api.c.lua_pushlightuserdata(state, host);
    lua_api.c.lua_pushcclosure(state, host_support.redactSecrets, 1);
    lua_api.c.lua_setfield(state, -2, "secrets");
    host_support.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, -1, "json");
    lua_api.c.lua_pushlightuserdata(state, host);
    lua_api.c.lua_pushcclosure(state, host_support.decodeJson, 1);
    lua_api.c.lua_setfield(state, -2, "decode");
    lua_api.c.lua_settop(state, 0);
}

fn installRequire(host: *Host) void {
    const state = host.vm.state;
    lua_api.c.lua_createtable(state, 0, 16);
    host.module_cache_ref = lua_api.c.luaL_ref(state, lua_api.c.LUA_REGISTRYINDEX);
    lua_api.c.lua_pushlightuserdata(state, host);
    lua_api.c.lua_pushcclosure(state, host_support.requireLocal, 1);
    lua_api.c.lua_setglobal(state, "require");
}

fn loadPlugin(host: *Host, entry_path: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(host.io, entry_path, host.gpa, .limited(host_support.max_entry_bytes));
    defer host.gpa.free(source);
    host.vm.resetBudget(5_000_000, 200 * std.time.ns_per_ms);
    try host.vm.evaluate(source, "@tap-plugin.lua");
    const state = host.vm.state;
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        return error.InvalidTapPlugin;
    }
    _ = lua_api.c.lua_getfield(state, -1, "on_exchange");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TFUNCTION) {
        return error.MissingExchangeHandler;
    }
    host.callback_ref = lua_api.c.luaL_ref(state, lua_api.c.LUA_REGISTRYINDEX);
    lua_api.c.lua_settop(state, 0);
}

pub fn invoke(host: *Host, exchange: ExchangeType) !BatchType {
    const state = host.vm.state;
    lua_api.c.lua_settop(state, 0);
    defer lua_api.c.lua_settop(state, 0);
    host.vm.resetBudget(5_000_000, 200 * std.time.ns_per_ms);
    _ = lua_api.c.lua_rawgeti(state, lua_api.c.LUA_REGISTRYINDEX, host.callback_ref);
    host_support.pushExchange(state, exchange);
    if (lua_api.c.lua_pcallk(state, 1, 1, 0, 0, null) != lua_api.c.LUA_OK) {
        return error.TapCallbackFailed;
    }
    return host_support.parseEffects(state, -1);
}
