//! Sandboxed local-module loading and dependency ownership for one Lua VM.
const std = @import("std");
const lua = @import("lua-api").c;
const Vm = @import("telar-lua").Vm;
const Io = std.Io;
const values = @import("lua_value.zig");
const string = values.string;
const pop = values.pop;
const raiseLua = values.raise;
pub const max_local_modules = 64;

pub const State = struct {
    vm: *Vm,
    config_dir: [std.fs.max_path_bytes]u8 = undefined,
    config_dir_len: u16 = 0,
    module_cache_ref: c_int = lua.LUA_NOREF,
    dependencies: [max_local_modules][std.fs.max_path_bytes]u8 = undefined,
    dependency_lens: [max_local_modules]u16 = undefined,
    dependency_mtimes: [max_local_modules]i128 = undefined,
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

    pub fn watchFingerprint(modules: *const State, io: Io, config_path: []const u8) i128 {
        var hasher = std.hash.Wyhash.init(0x74656c61722d6c75);
        updatePathFingerprint(&hasher, io, config_path);
        for (0..modules.dependency_count) |index|
            updatePathFingerprint(&hasher, io, modules.dependencyPath(index).?);
        return @intCast(hasher.final());
    }

    pub fn configDir(modules: *const State) []const u8 {
        return modules.config_dir[0..modules.config_dir_len];
    }

    pub fn installRequire(modules: *State) void {
        const state = modules.vm.state;
        lua.lua_createtable(state, 0, max_local_modules);
        modules.module_cache_ref = lua.luaL_ref(state, lua.LUA_REGISTRYINDEX);
        lua.lua_pushlightuserdata(state, modules);
        lua.lua_pushcclosure(state, requireLocal, 1);
        lua.lua_setglobal(state, "require");
    }
};

fn requireLocal(state: ?*lua.lua_State) callconv(.c) c_int {
    const lua_state = state.?;
    const context_ptr = lua.lua_touserdata(lua_state, lua.lua_upvalueindex(1)) orelse
        return raiseLua(lua_state, "missing Telar require context");
    const modules: *State = @ptrCast(@alignCast(context_ptr));
    const name = string(lua_state, 1) orelse
        return raiseLua(lua_state, "require expects a module name");
    if (std.mem.eql(u8, name, "telar")) {
        _ = lua.lua_getglobal(lua_state, "telar");
        return 1;
    }
    if (!validModuleName(name)) {
        return raiseLua(lua_state, "module names may contain letters, digits, '_', '-', and '.' only");
    }

    _ = lua.lua_rawgeti(lua_state, lua.LUA_REGISTRYINDEX, modules.module_cache_ref);
    _ = lua.lua_pushlstring(lua_state, name.ptr, name.len);
    _ = lua.lua_rawget(lua_state, -2);
    if (lua.lua_type(lua_state, -1) != lua.LUA_TNIL) {
        lua.lua_remove(lua_state, -2);
        return 1;
    }
    pop(lua_state, 1);

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var cursor: usize = 0;
    const config_dir = modules.config_dir[0..modules.config_dir_len];
    if (config_dir.len != 0 and !std.mem.eql(u8, config_dir, ".")) {
        if (config_dir.len + 1 > path_buffer.len) {
            return raiseLua(lua_state, "module path is too long");
        }
        @memcpy(path_buffer[0..config_dir.len], config_dir);
        cursor = config_dir.len;
        path_buffer[cursor] = std.fs.path.sep;
        cursor += 1;
    }
    if (name.len + ".lua".len > path_buffer.len - cursor) {
        return raiseLua(lua_state, "module path is too long");
    }
    for (name) |byte| {
        path_buffer[cursor] = if (byte == '.') std.fs.path.sep else byte;
        cursor += 1;
    }
    @memcpy(path_buffer[cursor..][0..".lua".len], ".lua");
    cursor += ".lua".len;
    if (cursor == path_buffer.len) {
        return raiseLua(lua_state, "module path is too long");
    }
    path_buffer[cursor] = 0;
    var resolved_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_len = Io.Dir.cwd().realPathFile(
        modules.vm.io,
        path_buffer[0..cursor],
        &resolved_buffer,
    ) catch return raiseLua(lua_state, "cannot resolve local configuration module");
    const resolved = resolved_buffer[0..resolved_len];
    if (!pathInside(modules.configDir(), resolved)) {
        return raiseLua(lua_state, "local configuration module escapes the configuration directory");
    }
    if (resolved_len == resolved_buffer.len) {
        return raiseLua(lua_state, "module path is too long");
    }
    resolved_buffer[resolved_len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(resolved_buffer[0..resolved_len :0]);

    if (lua.luaL_loadfilex(lua_state, path_z, "t") != lua.LUA_OK) {
        return lua.lua_error(lua_state);
    }
    if (lua.lua_pcallk(lua_state, 0, 1, 0, 0, null) != lua.LUA_OK) {
        return lua.lua_error(lua_state);
    }
    if (lua.lua_type(lua_state, -1) == lua.LUA_TNIL) {
        pop(lua_state, 1);
        lua.lua_pushboolean(lua_state, 1);
    }

    if (modules.dependency_count == max_local_modules) {
        return raiseLua(lua_state, "configuration requires too many local modules");
    }
    const dependency_index = modules.dependency_count;
    @memcpy(modules.dependencies[dependency_index][0..resolved_len], resolved);
    modules.dependency_lens[dependency_index] = @intCast(resolved_len);
    const stat = Io.Dir.cwd().statFile(modules.vm.io, resolved, .{}) catch
        return raiseLua(lua_state, "cannot stat loaded configuration module");
    modules.dependency_mtimes[dependency_index] = stat.mtime.nanoseconds;
    modules.dependency_count += 1;

    _ = lua.lua_pushlstring(lua_state, name.ptr, name.len);
    lua.lua_pushvalue(lua_state, -2);
    lua.lua_rawset(lua_state, -4);
    lua.lua_remove(lua_state, -2);
    return 1;
}

fn validModuleName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.' or name[name.len - 1] == '.') {
        return false;
    }
    var previous_dot = false;
    for (name) |byte| {
        if (byte == '.') {
            if (previous_dot) {
                return false;
            }
            previous_dot = true;
            continue;
        }
        previous_dot = false;
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') {
            return false;
        }
    }
    return true;
}

fn pathInside(root: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, root)) {
        return false;
    }
    return candidate.len == root.len or
        (candidate.len > root.len and candidate[root.len] == std.fs.path.sep);
}

fn updatePathFingerprint(hasher: *std.hash.Wyhash, io: Io, path: []const u8) void {
    hasher.update(path);
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch {
        hasher.update("\x00missing");
        return;
    };
    hasher.update(std.mem.asBytes(&stat.kind));
    hasher.update(std.mem.asBytes(&stat.size));
    hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
}
