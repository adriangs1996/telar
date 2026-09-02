//! Compiler for client themes and light/dark appearance variants.

const std = @import("std");
const core = @import("telar-core");
const lua = @import("lua-api").c;
const config_model = @import("model.zig");
const value = @import("lua_value.zig");
const theme_mod = @import("../ui/root.zig").theme;

pub fn parse(state: *lua.lua_State, index: c_int, diagnostic: *config_model.Diagnostic) !theme_mod.Theme {
    const absolute = lua.lua_absindex(state, index);
    if (value.string(state, absolute)) |name| {
        return theme_mod.fromName(name) orelse {
            diagnostic.set("unknown theme '{s}'", .{name});
            return error.InvalidConfig;
        };
    }
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.client.theme must be a name or table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "base", "colors" },
        .path = "config.client.theme",
    }, diagnostic);
    _ = lua.lua_getfield(state, absolute, "base");
    const base_name = value.string(state, -1) orelse {
        value.pop(state, 1);
        diagnostic.set("config.client.theme.base must be a string", .{});
        return error.InvalidConfig;
    };
    var result = theme_mod.fromName(base_name) orelse {
        diagnostic.set("unknown base theme '{s}'", .{base_name});
        value.pop(state, 1);
        return error.InvalidConfig;
    };
    value.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "colors");
    if (lua.lua_type(state, -1) == lua.LUA_TNIL) {
        value.pop(state, 1);
        return result;
    }
    if (lua.lua_type(state, -1) != lua.LUA_TTABLE) {
        value.pop(state, 1);
        diagnostic.set("config.client.theme.colors must be a table", .{});
        return error.InvalidConfig;
    }

    try ensureColorFields(state, -1, diagnostic);
    var overrides: theme_mod.Overrides = .{};
    inline for (std.meta.fields(theme_mod.Overrides)) |field| {
        _ = lua.lua_getfield(state, -1, field.name);
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            @field(overrides, field.name) = try parseColor(state, .{ .index = -1, .field = field.name }, diagnostic);
        }
        value.pop(state, 1);
    }
    value.pop(state, 1);
    result = result.withOverrides(overrides);
    return result;
}

pub fn parseAppearance(state: *lua.lua_State, snapshot: *config_model.Snapshot, diagnostic: *config_model.Diagnostic) !void {
    const absolute = lua.lua_absindex(state, -1);
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("config.client.appearance must be a table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "light", "dark" },
        .path = "config.client.appearance",
    }, diagnostic);
    _ = lua.lua_getfield(state, absolute, "light");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        snapshot.theme_light = try parse(state, -1, diagnostic);
    }
    value.pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "dark");
    if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
        snapshot.theme_dark = try parse(state, -1, diagnostic);
    }
    value.pop(state, 1);
}

fn ensureColorFields(state: *lua.lua_State, index: c_int, diagnostic: *config_model.Diagnostic) !void {
    const absolute = lua.lua_absindex(state, index);
    lua.lua_pushnil(state);
    while (lua.lua_next(state, absolute) != 0) {
        const key = value.string(state, -2) orelse {
            value.pop(state, 2);
            diagnostic.set("theme colors contain a non-string field", .{});
            return error.InvalidConfig;
        };
        const known = inline for (std.meta.fields(theme_mod.Overrides)) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                break true;
            }
        } else false;
        value.pop(state, 1);
        if (!known) {
            diagnostic.set("unknown theme color '{s}'", .{key});
            value.pop(state, 1);
            return error.InvalidConfig;
        }
    }
}

const ColorInput = struct {
    index: c_int,
    field: []const u8,
};

fn parseColor(state: *lua.lua_State, input: ColorInput, diagnostic: *config_model.Diagnostic) !core.ui.Color {
    const text = value.string(state, input.index) orelse {
        diagnostic.set("theme color {s} must be a string", .{input.field});
        return error.InvalidConfig;
    };
    if (std.mem.eql(u8, text, "default")) {
        return .default;
    }
    if (text.len != 7 or text[0] != '#') {
        diagnostic.set("theme color {s} must be #RRGGBB or default", .{input.field});
        return error.InvalidConfig;
    }

    const rgb = std.fmt.parseUnsigned(u24, text[1..], 16) catch {
        diagnostic.set("theme color {s} contains invalid hexadecimal digits", .{input.field});
        return error.InvalidConfig;
    };
    return .{ .rgb = .{
        @intCast((rgb >> 16) & 0xff),
        @intCast((rgb >> 8) & 0xff),
        @intCast(rgb & 0xff),
    } };
}
