//! Compiler for client themes and light/dark appearance variants.

const lua_api = @import("lua-api");
const DiagnosticType = @import("Diagnostic.zig");
const ThemeType = @import("../appearance/Theme.zig");
const value = @import("lua_value.zig");
const theme_mod = @import("../appearance/theme_support.zig");
const OverridesType = @import("../appearance/Overrides.zig");
const std = @import("std");
const SnapshotType = @import("Snapshot.zig");
const ColorInput = @import("ColorInput.zig");
const ColorType = @import("telar-core").Color;

pub fn parse(state: *lua_api.c.lua_State, index: c_int, diagnostic: *DiagnosticType) !ThemeType {
    const absolute = lua_api.c.lua_absindex(state, index);
    if (value.string(state, absolute)) |name| {
        return theme_mod.fromName(name) orelse {
            diagnostic.set("unknown theme '{s}'", .{name});
            return error.InvalidConfig;
        };
    }
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.theme must be a name or table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "base", "colors" },
        .path = "config.client.theme",
    }, diagnostic);
    _ = lua_api.c.lua_getfield(state, absolute, "base");
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

    _ = lua_api.c.lua_getfield(state, absolute, "colors");
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
        value.pop(state, 1);
        return result;
    }
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        value.pop(state, 1);
        diagnostic.set("config.client.theme.colors must be a table", .{});
        return error.InvalidConfig;
    }

    try ensureColorFields(state, -1, diagnostic);
    var overrides: OverridesType = .{};
    inline for (std.meta.fields(OverridesType)) |field| {
        _ = lua_api.c.lua_getfield(state, -1, field.name);
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
            @field(overrides, field.name) = try parseColor(state, .{ .index = -1, .field = field.name }, diagnostic);
        }
        value.pop(state, 1);
    }
    value.pop(state, 1);
    result = result.withOverrides(overrides);
    return result;
}

pub fn parseAppearance(state: *lua_api.c.lua_State, snapshot: *SnapshotType, diagnostic: *DiagnosticType) !void {
    const absolute = lua_api.c.lua_absindex(state, -1);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("config.client.appearance must be a table", .{});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "light", "dark" },
        .path = "config.client.appearance",
    }, diagnostic);
    _ = lua_api.c.lua_getfield(state, absolute, "light");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        snapshot.theme_light = try parse(state, -1, diagnostic);
    }
    value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "dark");
    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
        snapshot.theme_dark = try parse(state, -1, diagnostic);
    }
    value.pop(state, 1);
}

fn ensureColorFields(state: *lua_api.c.lua_State, index: c_int, diagnostic: *DiagnosticType) !void {
    const absolute = lua_api.c.lua_absindex(state, index);
    lua_api.c.lua_pushnil(state);
    while (lua_api.c.lua_next(state, absolute) != 0) {
        const key = value.string(state, -2) orelse {
            value.pop(state, 2);
            diagnostic.set("theme colors contain a non-string field", .{});
            return error.InvalidConfig;
        };
        const known = inline for (std.meta.fields(OverridesType)) |field| {
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

fn parseColor(state: *lua_api.c.lua_State, input: ColorInput, diagnostic: *DiagnosticType) !ColorType {
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
