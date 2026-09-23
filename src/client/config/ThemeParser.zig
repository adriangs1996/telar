//! One preset with optional chrome and terminal color overrides.
const data = @import("model");
const lua_api = @import("lua-api");
const core = @import("telar-core");
const std = @import("std");
const value = @import("lua_value.zig");
const Snapshot = @import("Snapshot.zig");
const Parser = @This();

state: *lua_api.c.lua_State,
diagnostic: *data.Diagnostic,

/// Selects the root/profile theme. The old client spelling is an exclusive alias.
/// Example: `snapshot.theme = try parser.select(snapshot.theme);`
pub fn select(self: Parser, initial: data.ColorTheme) !data.ColorTheme {
    const parent = lua_api.c.lua_absindex(self.state, -1);
    _ = lua_api.c.lua_getfield(self.state, parent, "theme");
    const primary = lua_api.c.lua_absindex(self.state, -1);
    _ = lua_api.c.lua_getfield(self.state, parent, "client");
    if (lua_api.c.lua_type(self.state, -1) == lua_api.c.LUA_TTABLE) {
        _ = lua_api.c.lua_getfield(self.state, -1, "theme");
    } else {
        lua_api.c.lua_pushnil(self.state);
    }
    defer value.pop(self.state, 3);

    if (lua_api.c.lua_type(self.state, primary) != lua_api.c.LUA_TNIL) {
        if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
            return self.invalid("select theme once: move client.theme to theme and remove the duplicate");
        }

        return self.parse(primary, initial);
    }

    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        return self.parse(-1, initial);
    }

    return initial;
}

/// A name/base replaces the preset; a table without base overlays inherited values.
/// Example: `const theme = try parser.parse(-1, parent_theme);`
pub fn parse(self: Parser, index: c_int, initial: data.ColorTheme) !data.ColorTheme {
    const absolute = lua_api.c.lua_absindex(self.state, index);
    if (value.string(self.state, absolute)) |name| {
        return data.theme_support.fromName(name) orelse {
            self.diagnostic.set("unknown theme '{s}'", .{name});
            return error.InvalidConfig;
        };
    }

    if (lua_api.c.lua_type(self.state, absolute) != lua_api.c.LUA_TTABLE) {
        return self.invalid("config.theme must be a name or table");
    }

    try value.ensureOnlyFields(self.state, .{ .index = absolute, .allowed = &.{ "base", "colors", "terminal", "syntax" }, .path = "config.theme" }, self.diagnostic);
    var result = initial;
    _ = lua_api.c.lua_getfield(self.state, absolute, "base");
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        const name = value.string(self.state, -1) orelse return self.invalid("config.theme.base must be a string");
        result = data.theme_support.fromName(name) orelse {
            self.diagnostic.set("unknown base theme '{s}'", .{name});
            return error.InvalidConfig;
        };
    }
    value.pop(self.state, 1);

    _ = lua_api.c.lua_getfield(self.state, absolute, "colors");
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        result = result.withOverrides(try self.chrome());
    }
    value.pop(self.state, 1);

    _ = lua_api.c.lua_getfield(self.state, absolute, "terminal");
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        result.terminal = try self.terminal(result.terminal);
    }
    value.pop(self.state, 1);

    _ = lua_api.c.lua_getfield(self.state, absolute, "syntax");
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        try self.syntax(&result);
    }
    value.pop(self.state, 1);
    return result;
}

fn syntax(self: Parser, theme: *data.ColorTheme) !void {
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TTABLE) {
        return self.invalid("theme.syntax must be a table of syntax roles");
    }

    const index = lua_api.c.lua_absindex(self.state, -1);
    lua_api.c.lua_pushnil(self.state);
    while (lua_api.c.lua_next(self.state, index) != 0) {
        const key = value.string(self.state, -2) orelse return self.invalid("theme.syntax roles must be strings");
        const role = std.meta.stringToEnum(data.role.Role, key) orelse {
            self.diagnostic.set("unknown syntax role '{s}'", .{key});
            return error.InvalidConfig;
        };
        var style = theme.syntaxStyle(role);
        if (lua_api.c.lua_type(self.state, -1) == lua_api.c.LUA_TTABLE) {
            try value.ensureOnlyFields(self.state, .{ .index = -1, .allowed = &.{ "fg", "italic", "bold" }, .path = "theme.syntax style" }, self.diagnostic);
            const entry = lua_api.c.lua_absindex(self.state, -1);
            _ = lua_api.c.lua_getfield(self.state, entry, "fg");
            if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
                style.color = try self.color(key);
            }
            value.pop(self.state, 1);

            inline for (.{ "italic", "bold" }) |field| {
                _ = lua_api.c.lua_getfield(self.state, entry, field);
                const kind = lua_api.c.lua_type(self.state, -1);
                if (kind != lua_api.c.LUA_TNIL) {
                    if (kind != lua_api.c.LUA_TBOOLEAN) {
                        return self.invalid("theme.syntax italic and bold must be booleans");
                    }

                    @field(style, field) = lua_api.c.lua_toboolean(self.state, -1) != 0;
                }
                value.pop(self.state, 1);
            }
        } else {
            style.color = try self.color(key);
        }

        theme.syntax_styles.set(role, style);
        value.pop(self.state, 1);
    }
}

/// Appearance variants use the same complete theme and retain profile inheritance.
/// Example: `try parser.appearance(&snapshot);`
pub fn appearance(self: Parser, snapshot: *Snapshot) !void {
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TTABLE) {
        return self.invalid("config.client.appearance must be a table");
    }

    try value.ensureOnlyFields(self.state, .{ .index = -1, .allowed = &.{ "light", "dark" }, .path = "config.client.appearance" }, self.diagnostic);
    _ = lua_api.c.lua_getfield(self.state, -1, "light");
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        snapshot.theme_light = try self.parse(-1, snapshot.theme_light orelse snapshot.theme);
    }
    value.pop(self.state, 1);

    _ = lua_api.c.lua_getfield(self.state, -1, "dark");
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        snapshot.theme_dark = try self.parse(-1, snapshot.theme_dark orelse snapshot.theme);
    }
    value.pop(self.state, 1);
}

fn chrome(self: Parser) !data.Overrides {
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TTABLE) {
        return self.invalid("config.theme.colors must be a table");
    }

    const index = lua_api.c.lua_absindex(self.state, -1);
    lua_api.c.lua_pushnil(self.state);
    while (lua_api.c.lua_next(self.state, index) != 0) {
        const key = value.string(self.state, -2) orelse return self.invalid("theme colors contain a non-string field");
        const known = inline for (std.meta.fields(data.Overrides)) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                break true;
            }
        } else false;
        if (!known) {
            self.diagnostic.set("unknown theme color '{s}'", .{key});
            return error.InvalidConfig;
        }

        value.pop(self.state, 1);
    }

    var overrides: data.Overrides = .{};
    inline for (std.meta.fields(data.Overrides)) |field| {
        _ = lua_api.c.lua_getfield(self.state, index, field.name);
        if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
            @field(overrides, field.name) = try self.color(field.name);
        }
        value.pop(self.state, 1);
    }
    return overrides;
}

fn terminal(self: Parser, initial: data.TerminalTheme) !data.TerminalTheme {
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TTABLE) {
        return self.invalid("theme.terminal must be a table");
    }

    try value.ensureOnlyFields(self.state, .{ .index = -1, .allowed = &.{ "foreground", "background", "palette", "cursor_color", "cursor_text_color" }, .path = "theme.terminal" }, self.diagnostic);
    var result = initial;
    inline for (.{ "foreground", "background", "cursor_color", "cursor_text_color" }) |field| {
        _ = lua_api.c.lua_getfield(self.state, -1, field);
        if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
            @field(result, field) = try self.rgb(field);
        }
        value.pop(self.state, 1);
    }

    _ = lua_api.c.lua_getfield(self.state, -1, "palette");
    defer value.pop(self.state, 1);
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TTABLE) {
            return self.invalid("theme.terminal.palette must contain 16 #RRGGBB colors in ANSI order");
        }

        try value.ensureArrayOnly(self.state, .{ .index = -1, .count = 16, .path = "theme.terminal.palette" }, self.diagnostic);
        for (&result.palette, 0..) |*entry, index| {
            _ = lua_api.c.lua_rawgeti(self.state, -1, @intCast(index + 1));
            entry.* = try self.rgb("palette");
            value.pop(self.state, 1);
        }
    }

    return result;
}

fn rgb(self: Parser, field: []const u8) ![3]u8 {
    const parsed = try self.color(field);
    return parsed.rgbChannels() orelse self.invalid("theme.terminal colors must be explicit #RRGGBB values");
}

fn color(self: Parser, field: []const u8) !core.Color {
    const text = value.string(self.state, -1) orelse return self.invalid("theme colors must be strings");
    if (std.mem.eql(u8, text, "default")) {
        return .default;
    }

    if (text.len != 7 or text[0] != '#') {
        self.diagnostic.set("theme color {s} must be #RRGGBB or default", .{field});
        return error.InvalidConfig;
    }

    var result: [3]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, text[1..]) catch {
        self.diagnostic.set("theme color {s} contains invalid hexadecimal digits", .{field});
        return error.InvalidConfig;
    };
    return .rgb(result);
}

fn invalid(self: Parser, message: []const u8) error{InvalidConfig} {
    self.diagnostic.set("{s}", .{message});
    return error.InvalidConfig;
}
