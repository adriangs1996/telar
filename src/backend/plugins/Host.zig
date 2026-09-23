const lua = @import("telar-lua");
const std = @import("std");
const lua_api = @import("lua-api");
const host_support = @import("host_support.zig");
const Exchange = @import("Exchange.zig");
const Batch = @import("Batch.zig");
const Host = @This();

io: std.Io,
gpa: std.mem.Allocator,
vm: *lua.Vm,
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
        .vm = try lua.Vm.init(io, .{
            .memory = 64 * 1024 * 1024,
            .instructions = 5_000_000,
            .deadline_after_ns = 200 * std.time.ns_per_ms,
        }),
        .package_root = try gpa.dupe(u8, root),
    };
    errdefer host.deinit();
    try lua.open(host.vm.state);
    try host.installTelar();
    host.installRequire();
    try host.loadPlugin(entry_path);
    return host;
}

pub fn deinit(self: *Host) void {
    self.vm.deinit();
    self.gpa.free(self.package_root);
}

fn installTelar(self: *Host) !void {
    try self.vm.evaluate(@embedFile("bootstrap.lua"), "@telar-tap-bootstrap.lua");
    const state = self.vm.state;
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        return error.InvalidBootstrap;
    }
    lua_api.c.lua_pushvalue(state, -1);
    lua_api.c.lua_setglobal(state, "telar");

    _ = lua_api.c.lua_getfield(state, -1, "redact");
    lua_api.c.lua_pushlightuserdata(state, self);
    lua_api.c.lua_pushcclosure(state, host_support.redactSecrets, 1);
    lua_api.c.lua_setfield(state, -2, "secrets");
    host_support.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, -1, "json");
    lua_api.c.lua_pushlightuserdata(state, self);
    lua_api.c.lua_pushcclosure(state, host_support.decodeJson, 1);
    lua_api.c.lua_setfield(state, -2, "decode");
    lua_api.c.lua_settop(state, 0);
}

fn installRequire(self: *Host) void {
    const state = self.vm.state;
    lua_api.c.lua_createtable(state, 0, 16);
    self.module_cache_ref = lua_api.c.luaL_ref(state, lua_api.c.LUA_REGISTRYINDEX);
    lua_api.c.lua_pushlightuserdata(state, self);
    lua_api.c.lua_pushcclosure(state, host_support.requireLocal, 1);
    lua_api.c.lua_setglobal(state, "require");
}

fn loadPlugin(self: *Host, entry_path: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(self.io, entry_path, self.gpa, .limited(host_support.max_entry_bytes));
    defer self.gpa.free(source);
    self.vm.resetBudget(5_000_000, 200 * std.time.ns_per_ms);
    try self.vm.evaluate(source, "@tap-plugin.lua");
    const state = self.vm.state;
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        return error.InvalidTapPlugin;
    }
    _ = lua_api.c.lua_getfield(state, -1, "on_exchange");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TFUNCTION) {
        return error.MissingExchangeHandler;
    }
    self.callback_ref = lua_api.c.luaL_ref(state, lua_api.c.LUA_REGISTRYINDEX);
    lua_api.c.lua_settop(state, 0);
}

pub fn invoke(self: *Host, exchange: Exchange) !Batch {
    const state = self.vm.state;
    lua_api.c.lua_settop(state, 0);
    defer lua_api.c.lua_settop(state, 0);
    self.vm.resetBudget(5_000_000, 200 * std.time.ns_per_ms);
    _ = lua_api.c.lua_rawgeti(state, lua_api.c.LUA_REGISTRYINDEX, self.callback_ref);
    host_support.pushExchange(state, exchange);
    if (lua_api.c.lua_pcallk(state, 1, 1, 0, 0, null) != lua_api.c.LUA_OK) {
        return error.TapCallbackFailed;
    }
    return host_support.parseEffects(state, -1);
}
