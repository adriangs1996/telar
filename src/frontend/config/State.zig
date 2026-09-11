const State = @This();
const Vm = @import("telar-lua").Vm;
const std = @import("std");
const lua = @import("lua-api").c;
const source_namespace = @import("local_modules.zig");
vm: *Vm,
config_dir: [std.fs.max_path_bytes]u8 = undefined,
config_dir_len: u16 = 0,
module_cache_ref: c_int = lua.LUA_NOREF,
dependencies: [source_namespace.max_local_modules][std.fs.max_path_bytes]u8 = undefined,
dependency_lens: [source_namespace.max_local_modules]u16 = undefined,
dependency_mtimes: [source_namespace.max_local_modules]i128 = undefined,
dependency_count: u8 = 0,

/// Creates the loader before any closure can borrow its stable address.
/// Example: `modules = try State.init(vm, config_dir);`.
pub fn init(vm: *Vm, path: []const u8) !State {
    var modules: State = .{ .vm = vm };
    if (path.len > modules.config_dir.len) {
        return error.NameTooLong;
    }

    @memcpy(modules.config_dir[0..path.len], path);
    modules.config_dir_len = @intCast(path.len);
    return modules;
}

pub fn dependencyPath(modules: *const State, index: usize) ?[]const u8 {
    if (index >= modules.dependency_count) {
        return null;
    }
    return modules.dependencies[index][0..modules.dependency_lens[index]];
}

pub fn watchFingerprint(modules: *const State, io: source_namespace.Io, config_path: []const u8) i128 {
    var hasher = std.hash.Wyhash.init(0x74656c61722d6c75);
    source_namespace.updatePathFingerprint(&hasher, io, config_path);
    for (0..modules.dependency_count) |index|
        source_namespace.updatePathFingerprint(&hasher, io, modules.dependencyPath(index).?);
    return @intCast(hasher.final());
}

pub fn configDir(modules: *const State) []const u8 {
    return modules.config_dir[0..modules.config_dir_len];
}

pub fn installRequire(modules: *State) void {
    const state = modules.vm.state;
    lua.lua_createtable(state, 0, source_namespace.max_local_modules);
    modules.module_cache_ref = lua.luaL_ref(state, lua.LUA_REGISTRYINDEX);
    lua.lua_pushlightuserdata(state, modules);
    lua.lua_pushcclosure(state, source_namespace.requireLocal, 1);
    lua.lua_setglobal(state, "require");
}
