const lua = @import("telar-lua");
const std = @import("std");
const lua_api = @import("lua-api");
const local_modules = @import("local_modules.zig");
const State = @This();

vm: *lua.Vm,
config_dir: [std.fs.max_path_bytes]u8 = undefined,
config_dir_len: u16 = 0,
module_cache_ref: c_int = lua_api.c.LUA_NOREF,
dependencies: [local_modules.max_local_modules][std.fs.max_path_bytes]u8 = undefined,
dependency_lens: [local_modules.max_local_modules]u16 = undefined,
dependency_mtimes: [local_modules.max_local_modules]i128 = undefined,
dependency_count: u8 = 0,

/// Creates the loader before any closure can borrow its stable address.
/// Example: `modules = try State.init(vm, config_dir);`.
pub fn init(vm: *lua.Vm, path: []const u8) !State {
    var modules: State = .{ .vm = vm };
    if (path.len > modules.config_dir.len) {
        return error.NameTooLong;
    }

    @memcpy(modules.config_dir[0..path.len], path);
    modules.config_dir_len = @intCast(path.len);
    return modules;
}

pub fn dependencyPath(self: *const State, index: usize) ?[]const u8 {
    if (index >= self.dependency_count) {
        return null;
    }
    return self.dependencies[index][0..self.dependency_lens[index]];
}

pub fn watchFingerprint(self: *const State, io: std.Io, config_path: []const u8) i128 {
    var hasher = std.hash.Wyhash.init(0x74656c61722d6c75);
    local_modules.updatePathFingerprint(&hasher, io, config_path);
    for (0..self.dependency_count) |index|
        local_modules.updatePathFingerprint(&hasher, io, self.dependencyPath(index).?);
    return @intCast(hasher.final());
}

pub fn configDir(self: *const State) []const u8 {
    return self.config_dir[0..self.config_dir_len];
}

pub fn installRequire(self: *State) void {
    const state = self.vm.state;
    lua_api.c.lua_createtable(state, 0, local_modules.max_local_modules);
    self.module_cache_ref = lua_api.c.luaL_ref(state, lua_api.c.LUA_REGISTRYINDEX);
    lua_api.c.lua_pushlightuserdata(state, self);
    lua_api.c.lua_pushcclosure(state, local_modules.requireLocal, 1);
    lua_api.c.lua_setglobal(state, "require");
}
