//! `telar.json.decode`: bounded JSON into plain Lua tables, shared by the
//! configuration VM and the plugin host.
const lua_api = @import("lua-api");
const std = @import("std");
const Vm = @import("Vm.zig");

pub const max_input_bytes = 1024 * 1024;
const max_depth: u8 = 64;

/// Installs `json.decode` on the table at the top of the stack.
/// Example: `json.install(state); // telar.json.decode(text) in Lua`
pub fn install(state: *lua_api.c.lua_State) void {
    lua_api.c.lua_createtable(state, 0, 1);
    lua_api.c.lua_pushcclosure(state, decode, 0);
    lua_api.c.lua_setfield(state, -2, "decode");
    lua_api.c.lua_setfield(state, -2, "json");
}

/// The C function behind `json.decode(text)`.
///
/// The parsed document lives outside the Lua heap, so the Lua values are
/// built inside a protected call: a Lua error there, such as running out of
/// the VM's memory, frees the document before the error propagates.
pub fn decode(state_optional: ?*lua_api.c.lua_State) callconv(.c) c_int {
    const state = state_optional.?;
    if (lua_api.c.lua_type(state, 1) != lua_api.c.LUA_TSTRING) {
        return raise(state, "json.decode expects a string");
    }

    var len: usize = 0;
    const text = lua_api.c.lua_tolstring(state, 1, &len) orelse return raise(state, "json.decode expects a string");
    if (len > max_input_bytes) {
        return raise(state, "JSON input is too large");
    }

    var parsed = std.json.parseFromSlice(std.json.Value, Vm.of(state).gpa, text[0..len], .{
        .max_value_len = max_input_bytes,
    }) catch return raise(state, "invalid JSON");
    lua_api.c.lua_pushcclosure(state, pushDocument, 0);
    lua_api.c.lua_pushlightuserdata(state, &parsed.value);
    const status = lua_api.c.lua_pcallk(state, 1, 1, 0, 0, null);
    parsed.deinit();
    if (status != lua_api.c.LUA_OK) {
        return lua_api.c.lua_error(state);
    }

    return 1;
}

fn pushDocument(state_optional: ?*lua_api.c.lua_State) callconv(.c) c_int {
    const state = state_optional.?;
    const value: *const std.json.Value = @ptrCast(@alignCast(lua_api.c.lua_touserdata(state, 1)));
    push(state, value.*, 0) catch return raise(state, "JSON exceeds the depth or number limits");
    return 1;
}

fn push(state: *lua_api.c.lua_State, value: std.json.Value, depth: u8) !void {
    if (depth == max_depth) {
        return error.JsonDepth;
    }

    switch (value) {
        .null => lua_api.c.lua_pushnil(state),
        .bool => |boolean| lua_api.c.lua_pushboolean(state, @intFromBool(boolean)),
        .integer => |integer| lua_api.c.lua_pushinteger(state, integer),
        .float => |float| lua_api.c.lua_pushnumber(state, float),
        .number_string => |number| {
            const parsed = std.fmt.parseFloat(f64, number) catch return error.InvalidJson;
            lua_api.c.lua_pushnumber(state, parsed);
        },
        .string => |string| _ = lua_api.c.lua_pushlstring(state, string.ptr, string.len),
        .array => |array| {
            lua_api.c.lua_createtable(state, @intCast(array.items.len), 0);
            for (array.items, 1..) |item, index| {
                try push(state, item, depth + 1);
                lua_api.c.lua_seti(state, -2, @intCast(index));
            }
        },
        .object => |object| {
            lua_api.c.lua_createtable(state, 0, @intCast(object.count()));
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                _ = lua_api.c.lua_pushlstring(state, entry.key_ptr.ptr, entry.key_ptr.len);
                try push(state, entry.value_ptr.*, depth + 1);
                lua_api.c.lua_settable(state, -3);
            }
        },
    }
}

fn raise(state: *lua_api.c.lua_State, message: [*:0]const u8) c_int {
    _ = lua_api.c.lua_pushstring(state, message);
    return lua_api.c.lua_error(state);
}
