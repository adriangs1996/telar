//! One preset with optional chrome and terminal color overrides.
const std = @import("std");
const lua = @import("lua-api").c;
const value = @import("lua_value.zig");
const Theme = @import("../appearance/Theme.zig");
const TerminalTheme = @import("../appearance/TerminalTheme.zig");
const Overrides = @import("../appearance/Overrides.zig");
const themes = @import("../appearance/theme_support.zig");
const Color = @import("telar-core").Color;
const Parser = @This();

state: *lua.lua_State,
diagnostic: *@import("Diagnostic.zig"),

/// Selects the root/profile theme. The old client spelling is an exclusive alias.
/// Example: `snapshot.theme = try parser.select(snapshot.theme);`
pub fn select(parser: Parser, initial: Theme) !Theme {
    const parent = lua.lua_absindex(parser.state, -1);
    _ = lua.lua_getfield(parser.state, parent, "theme");
    const primary = lua.lua_absindex(parser.state, -1);
    _ = lua.lua_getfield(parser.state, parent, "client");
    if (lua.lua_type(parser.state, -1) == lua.LUA_TTABLE) {
        _ = lua.lua_getfield(parser.state, -1, "theme");
    } else {
        lua.lua_pushnil(parser.state);
    }
    defer value.pop(parser.state, 3);

    if (lua.lua_type(parser.state, primary) != lua.LUA_TNIL) {
        if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
            return parser.invalid("select theme once: move client.theme to theme and remove the duplicate");
        }

        return parser.parse(primary, initial);
    }

    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        return parser.parse(-1, initial);
    }

    return initial;
}

/// A name/base replaces the preset; a table without base overlays inherited values.
/// Example: `const theme = try parser.parse(-1, parent_theme);`
pub fn parse(parser: Parser, index: c_int, initial: Theme) !Theme {
    const absolute = lua.lua_absindex(parser.state, index);
    if (value.string(parser.state, absolute)) |name| {
        return themes.fromName(name) orelse {
            parser.diagnostic.set("unknown theme '{s}'", .{name});
            return error.InvalidConfig;
        };
    }

    if (lua.lua_type(parser.state, absolute) != lua.LUA_TTABLE) {
        return parser.invalid("config.theme must be a name or table");
    }

    try value.ensureOnlyFields(parser.state, .{ .index = absolute, .allowed = &.{ "base", "colors", "terminal" }, .path = "config.theme" }, parser.diagnostic);
    var result = initial;
    _ = lua.lua_getfield(parser.state, absolute, "base");
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        const name = value.string(parser.state, -1) orelse return parser.invalid("config.theme.base must be a string");
        result = themes.fromName(name) orelse {
            parser.diagnostic.set("unknown base theme '{s}'", .{name});
            return error.InvalidConfig;
        };
    }
    value.pop(parser.state, 1);

    _ = lua.lua_getfield(parser.state, absolute, "colors");
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        result = result.withOverrides(try parser.chrome());
    }
    value.pop(parser.state, 1);

    _ = lua.lua_getfield(parser.state, absolute, "terminal");
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        result.terminal = try parser.terminal(result.terminal);
    }
    value.pop(parser.state, 1);
    return result;
}

/// Appearance variants use the same complete theme and retain profile inheritance.
/// Example: `try parser.appearance(&snapshot);`
pub fn appearance(parser: Parser, snapshot: *@import("Snapshot.zig")) !void {
    if (lua.lua_type(parser.state, -1) != lua.LUA_TTABLE) {
        return parser.invalid("config.client.appearance must be a table");
    }

    try value.ensureOnlyFields(parser.state, .{ .index = -1, .allowed = &.{ "light", "dark" }, .path = "config.client.appearance" }, parser.diagnostic);
    _ = lua.lua_getfield(parser.state, -1, "light");
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        snapshot.theme_light = try parser.parse(-1, snapshot.theme_light orelse snapshot.theme);
    }
    value.pop(parser.state, 1);

    _ = lua.lua_getfield(parser.state, -1, "dark");
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        snapshot.theme_dark = try parser.parse(-1, snapshot.theme_dark orelse snapshot.theme);
    }
    value.pop(parser.state, 1);
}

fn chrome(parser: Parser) !Overrides {
    if (lua.lua_type(parser.state, -1) != lua.LUA_TTABLE) {
        return parser.invalid("config.theme.colors must be a table");
    }

    const index = lua.lua_absindex(parser.state, -1);
    lua.lua_pushnil(parser.state);
    while (lua.lua_next(parser.state, index) != 0) {
        const key = value.string(parser.state, -2) orelse return parser.invalid("theme colors contain a non-string field");
        const known = inline for (std.meta.fields(Overrides)) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                break true;
            }
        } else false;
        if (!known) {
            parser.diagnostic.set("unknown theme color '{s}'", .{key});
            return error.InvalidConfig;
        }

        value.pop(parser.state, 1);
    }

    var overrides: Overrides = .{};
    inline for (std.meta.fields(Overrides)) |field| {
        _ = lua.lua_getfield(parser.state, index, field.name);
        if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
            @field(overrides, field.name) = try parser.color(field.name);
        }
        value.pop(parser.state, 1);
    }
    return overrides;
}

fn terminal(parser: Parser, initial: TerminalTheme) !TerminalTheme {
    if (lua.lua_type(parser.state, -1) != lua.LUA_TTABLE) {
        return parser.invalid("theme.terminal must be a table");
    }

    try value.ensureOnlyFields(parser.state, .{ .index = -1, .allowed = &.{ "foreground", "background", "palette", "cursor_color", "cursor_text_color" }, .path = "theme.terminal" }, parser.diagnostic);
    var result = initial;
    inline for (.{ "foreground", "background", "cursor_color", "cursor_text_color" }) |field| {
        _ = lua.lua_getfield(parser.state, -1, field);
        if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
            @field(result, field) = try parser.rgb(field);
        }
        value.pop(parser.state, 1);
    }

    _ = lua.lua_getfield(parser.state, -1, "palette");
    defer value.pop(parser.state, 1);
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        if (lua.lua_type(parser.state, -1) != lua.LUA_TTABLE) {
            return parser.invalid("theme.terminal.palette must contain 16 #RRGGBB colors in ANSI order");
        }

        try value.ensureArrayOnly(parser.state, .{ .index = -1, .count = 16, .path = "theme.terminal.palette" }, parser.diagnostic);
        for (&result.palette, 0..) |*entry, index| {
            _ = lua.lua_rawgeti(parser.state, -1, @intCast(index + 1));
            entry.* = try parser.rgb("palette");
            value.pop(parser.state, 1);
        }
    }

    return result;
}

fn rgb(parser: Parser, field: []const u8) ![3]u8 {
    return switch (try parser.color(field)) {
        .rgb => |bytes| bytes,
        else => parser.invalid("theme.terminal colors must be explicit #RRGGBB values"),
    };
}

fn color(parser: Parser, field: []const u8) !Color {
    const text = value.string(parser.state, -1) orelse return parser.invalid("theme colors must be strings");
    if (std.mem.eql(u8, text, "default")) {
        return .default;
    }

    if (text.len != 7 or text[0] != '#') {
        parser.diagnostic.set("theme color {s} must be #RRGGBB or default", .{field});
        return error.InvalidConfig;
    }

    var result: [3]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, text[1..]) catch {
        parser.diagnostic.set("theme color {s} contains invalid hexadecimal digits", .{field});
        return error.InvalidConfig;
    };
    return .{ .rgb = result };
}

fn invalid(parser: Parser, message: []const u8) error{InvalidConfig} {
    parser.diagnostic.set("{s}", .{message});
    return error.InvalidConfig;
}
