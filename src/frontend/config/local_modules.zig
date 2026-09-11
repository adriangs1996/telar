//! Sandboxed local-module loading and dependency ownership for one Lua VM.

const lua_api = @import("lua-api");
const values = @import("lua_value.zig");
const State = @import("State.zig");
const std = @import("std");

pub const max_local_modules = 64;

pub fn requireLocal(state: ?*lua_api.c.lua_State) callconv(.c) c_int {
    const lua_state = state.?;
    const context_ptr = lua_api.c.lua_touserdata(lua_state, lua_api.c.lua_upvalueindex(1)) orelse
        return values.raise(lua_state, "missing Telar require context");
    const modules: *State = @ptrCast(@alignCast(context_ptr));
    const name = values.string(lua_state, 1) orelse
        return values.raise(lua_state, "require expects a module name");
    if (std.mem.eql(u8, name, "telar")) {
        _ = lua_api.c.lua_getglobal(lua_state, "telar");
        return 1;
    }
    if (!validModuleName(name)) {
        return values.raise(lua_state, "module names may contain letters, digits, '_', '-', and '.' only");
    }

    _ = lua_api.c.lua_rawgeti(lua_state, lua_api.c.LUA_REGISTRYINDEX, modules.module_cache_ref);
    _ = lua_api.c.lua_pushlstring(lua_state, name.ptr, name.len);
    _ = lua_api.c.lua_rawget(lua_state, -2);
    if (lua_api.c.lua_type(lua_state, -1) != lua_api.c.LUA_TNIL) {
        lua_api.c.lua_remove(lua_state, -2);
        return 1;
    }
    values.pop(lua_state, 1);

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var cursor: usize = 0;
    const config_dir = modules.config_dir[0..modules.config_dir_len];
    if (config_dir.len != 0 and !std.mem.eql(u8, config_dir, ".")) {
        if (config_dir.len + 1 > path_buffer.len) {
            return values.raise(lua_state, "module path is too long");
        }
        @memcpy(path_buffer[0..config_dir.len], config_dir);
        cursor = config_dir.len;
        path_buffer[cursor] = std.fs.path.sep;
        cursor += 1;
    }
    if (name.len + ".lua".len > path_buffer.len - cursor) {
        return values.raise(lua_state, "module path is too long");
    }
    for (name) |byte| {
        path_buffer[cursor] = if (byte == '.') std.fs.path.sep else byte;
        cursor += 1;
    }
    @memcpy(path_buffer[cursor..][0..".lua".len], ".lua");
    cursor += ".lua".len;
    if (cursor == path_buffer.len) {
        return values.raise(lua_state, "module path is too long");
    }
    path_buffer[cursor] = 0;
    var resolved_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_len = std.Io.Dir.cwd().realPathFile(
        modules.vm.io,
        path_buffer[0..cursor],
        &resolved_buffer,
    ) catch return values.raise(lua_state, "cannot resolve local configuration module");
    const resolved = resolved_buffer[0..resolved_len];
    if (!pathInside(modules.configDir(), resolved)) {
        return values.raise(lua_state, "local configuration module escapes the configuration directory");
    }
    if (resolved_len == resolved_buffer.len) {
        return values.raise(lua_state, "module path is too long");
    }
    resolved_buffer[resolved_len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(resolved_buffer[0..resolved_len :0]);

    if (lua_api.c.luaL_loadfilex(lua_state, path_z, "t") != lua_api.c.LUA_OK) {
        return lua_api.c.lua_error(lua_state);
    }
    if (lua_api.c.lua_pcallk(lua_state, 0, 1, 0, 0, null) != lua_api.c.LUA_OK) {
        return lua_api.c.lua_error(lua_state);
    }
    if (lua_api.c.lua_type(lua_state, -1) == lua_api.c.LUA_TNIL) {
        values.pop(lua_state, 1);
        lua_api.c.lua_pushboolean(lua_state, 1);
    }

    if (modules.dependency_count == max_local_modules) {
        return values.raise(lua_state, "configuration requires too many local modules");
    }
    const dependency_index = modules.dependency_count;
    @memcpy(modules.dependencies[dependency_index][0..resolved_len], resolved);
    modules.dependency_lens[dependency_index] = @intCast(resolved_len);
    const stat = std.Io.Dir.cwd().statFile(modules.vm.io, resolved, .{}) catch
        return values.raise(lua_state, "cannot stat loaded configuration module");
    modules.dependency_mtimes[dependency_index] = stat.mtime.nanoseconds;
    modules.dependency_count += 1;

    _ = lua_api.c.lua_pushlstring(lua_state, name.ptr, name.len);
    lua_api.c.lua_pushvalue(lua_state, -2);
    lua_api.c.lua_rawset(lua_state, -4);
    lua_api.c.lua_remove(lua_state, -2);
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

pub fn updatePathFingerprint(hasher: *std.hash.Wyhash, io: std.Io, path: []const u8) void {
    hasher.update(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        hasher.update("\x00missing");
        return;
    };
    hasher.update(std.mem.asBytes(&stat.kind));
    hasher.update(std.mem.asBytes(&stat.size));
    hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
}
