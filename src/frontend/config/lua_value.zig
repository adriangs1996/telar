//! Typed, diagnostic-producing reads from the Lua stack.

const std = @import("std");
const lua = @import("lua-api").c;
const Diagnostic = @import("model.zig").Diagnostic;

pub fn raise(state: *lua.lua_State, message: [*:0]const u8) c_int {
    _ = lua.lua_pushstring(state, message);
    return lua.lua_error(state);
}

pub fn openLibrary(state: *lua.lua_State, name: [*:0]const u8, function: lua.lua_CFunction) void {
    lua.luaL_requiref(state, name, function, 1);
    pop(state, 1);
}

pub fn pop(state: *lua.lua_State, count: c_int) void {
    lua.lua_settop(state, -count - 1);
}

pub fn string(state: *lua.lua_State, index: c_int) ?[]const u8 {
    if (lua.lua_type(state, index) != lua.LUA_TSTRING) {
        return null;
    }

    var len: usize = 0;
    const value = lua.lua_tolstring(state, index, &len) orelse return null;
    return value[0..len];
}

pub fn integer(state: *lua.lua_State, index: c_int) ?lua.lua_Integer {
    var is_number: c_int = 0;
    const value = lua.lua_tointegerx(state, index, &is_number);
    return if (is_number == 1) value else null;
}

pub const RequiredField = struct {
    index: c_int,
    name: [*:0]const u8,
};

pub fn requiredStringField(state: *lua.lua_State, input: RequiredField, diagnostic: *Diagnostic) ![]const u8 {
    const absolute = lua.lua_absindex(state, input.index);
    _ = lua.lua_getfield(state, absolute, input.name);
    const value = string(state, -1) orelse {
        pop(state, 1);
        diagnostic.set("action.{s} must be a string", .{std.mem.span(input.name)});
        return error.InvalidConfig;
    };
    pop(state, 1);
    return value;
}

pub fn requiredIntegerField(state: *lua.lua_State, input: RequiredField, diagnostic: *Diagnostic) !lua.lua_Integer {
    const absolute = lua.lua_absindex(state, input.index);
    _ = lua.lua_getfield(state, absolute, input.name);
    const value = integer(state, -1) orelse {
        pop(state, 1);
        diagnostic.set("action.{s} must be an integer", .{std.mem.span(input.name)});
        return error.InvalidConfig;
    };
    pop(state, 1);
    return value;
}

pub const OptionalString = struct {
    index: c_int,
    name: [*:0]const u8,
    default: []const u8,
};

pub fn optionalStringField(state: *lua.lua_State, input: OptionalString, diagnostic: *Diagnostic) ![]const u8 {
    const absolute = lua.lua_absindex(state, input.index);
    _ = lua.lua_getfield(state, absolute, input.name);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        return input.default;
    }

    return string(state, -1) orelse {
        diagnostic.set("action.{s} must be a string", .{std.mem.span(input.name)});
        return error.InvalidConfig;
    };
}

pub const OptionalInteger = struct {
    index: c_int,
    name: [*:0]const u8,
    default: lua.lua_Integer,
};

pub fn optionalIntegerField(state: *lua.lua_State, input: OptionalInteger, diagnostic: *Diagnostic) !lua.lua_Integer {
    const absolute = lua.lua_absindex(state, input.index);
    _ = lua.lua_getfield(state, absolute, input.name);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        return input.default;
    }

    return integer(state, -1) orelse {
        diagnostic.set("action.{s} must be an integer", .{std.mem.span(input.name)});
        return error.InvalidConfig;
    };
}

pub fn optionalPositiveId(state: *lua.lua_State, input: RequiredField, diagnostic: *Diagnostic) !?u64 {
    const absolute = lua.lua_absindex(state, input.index);
    _ = lua.lua_getfield(state, absolute, input.name);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        return null;
    }

    const value = integer(state, -1) orelse {
        diagnostic.set("action.{s} must be an integer", .{std.mem.span(input.name)});
        return error.InvalidConfig;
    };
    if (value <= 0) {
        diagnostic.set("action.{s} must be positive", .{std.mem.span(input.name)});
        return error.InvalidConfig;
    }

    return @intCast(value);
}

pub const OptionalMebibytes = struct {
    index: c_int,
    name: [*:0]const u8,
    default: usize,
};

pub fn optionalMebibytes(state: *lua.lua_State, input: OptionalMebibytes, diagnostic: *Diagnostic) !usize {
    const absolute = lua.lua_absindex(state, input.index);
    _ = lua.lua_getfield(state, absolute, input.name);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        return input.default;
    }

    const value = integer(state, -1) orelse {
        diagnostic.set("runtime graphics {s} must be an integer", .{std.mem.span(input.name)});
        return error.InvalidConfig;
    };
    if (value <= 0 or value > std.math.maxInt(usize) / (1024 * 1024)) {
        diagnostic.set("runtime graphics {s} is out of range", .{std.mem.span(input.name)});
        return error.InvalidConfig;
    }

    return @as(usize, @intCast(value)) * 1024 * 1024;
}

pub const OptionalMilliseconds = struct {
    index: c_int,
    name: [*:0]const u8,
    default_ns: u64,
    minimum_ms: u64,
    maximum_ms: u64,
};

pub fn optionalMilliseconds(state: *lua.lua_State, input: OptionalMilliseconds, diagnostic: *Diagnostic) !u64 {
    const absolute = lua.lua_absindex(state, input.index);
    _ = lua.lua_getfield(state, absolute, input.name);
    defer pop(state, 1);
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        return input.default_ns;
    }

    const value = integer(state, -1) orelse {
        diagnostic.set("client input {s} must be an integer", .{std.mem.span(input.name)});
        return error.InvalidConfig;
    };
    if (value < input.minimum_ms or value > input.maximum_ms) {
        diagnostic.set(
            "client input {s} must be in {d}..{d} milliseconds",
            .{ std.mem.span(input.name), input.minimum_ms, input.maximum_ms },
        );
        return error.InvalidConfig;
    }

    return @as(u64, @intCast(value)) * std.time.ns_per_ms;
}

pub const Fields = struct {
    index: c_int,
    allowed: []const []const u8,
    path: []const u8,
};

pub fn ensureOnlyFields(state: *lua.lua_State, fields: Fields, diagnostic: *Diagnostic) !void {
    const absolute = lua.lua_absindex(state, fields.index);
    lua.lua_pushnil(state);
    while (lua.lua_next(state, absolute) != 0) {
        const key = string(state, -2) orelse {
            pop(state, 2);
            diagnostic.set("{s} contains a non-string field", .{fields.path});
            return error.InvalidConfig;
        };
        const known = for (fields.allowed) |name| {
            if (std.mem.eql(u8, key, name)) {
                break true;
            }
        } else false;
        pop(state, 1);
        if (!known) {
            diagnostic.set("unknown field {s}.{s}", .{ fields.path, key });
            pop(state, 1);
            return error.InvalidConfig;
        }
    }
}

pub const Array = struct {
    index: c_int,
    count: usize,
    path: []const u8,
};

pub fn ensureArrayOnly(state: *lua.lua_State, input: Array, diagnostic: *Diagnostic) !void {
    const absolute = lua.lua_absindex(state, input.index);
    lua.lua_pushnil(state);
    while (lua.lua_next(state, absolute) != 0) {
        if (lua.lua_type(state, -2) != lua.LUA_TNUMBER or lua.lua_isinteger(state, -2) == 0) {
            pop(state, 2);
            diagnostic.set("{s} must be an array", .{input.path});
            return error.InvalidConfig;
        }

        const key = integer(state, -2).?;
        const valid = key >= 1 and key <= input.count;
        pop(state, 1);
        if (!valid) {
            pop(state, 1);
            diagnostic.set("{s} must be an array", .{input.path});
            return error.InvalidConfig;
        }
    }
}
