const lua_api = @import("lua-api");
const data = @import("model");
const std = @import("std");
const value = @import("lua_value.zig");
const Config = @import("GuiConfig.zig");
const Cursor = @import("GuiCursor.zig");
const Sidebar = @import("GuiSidebar.zig");
const GuiChrome = @import("GuiChrome.zig");
const GuiWindow = @import("GuiWindow.zig");
const Parser = @This();

state: *lua_api.c.lua_State,
diagnostic: *data.Diagnostic,

/// Overlays validated native preferences on a config or profile snapshot.
/// Example: `snapshot.gui = try parser.parse(snapshot.gui);`
pub fn parse(self: Parser, initial: Config) !Config {
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TTABLE) {
        return self.invalid("config.gui must be a table");
    }

    _ = lua_api.c.lua_getfield(self.state, -1, "theme");
    const old_theme = lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL;
    value.pop(self.state, 1);
    if (old_theme) {
        return self.invalid("gui.theme moved to theme.terminal; select a preset once with theme = 'vesper'");
    }

    try self.table("config.gui", &.{ "font", "cursor", "window", "chrome", "sidebar" });
    var result = initial;
    _ = lua_api.c.lua_getfield(self.state, -1, "font");
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        try self.table("config.gui.font", &.{ "family", "size", "line_height", "letter_spacing", "thicken", "thicken_strength" });
        _ = lua_api.c.lua_getfield(self.state, -1, "family");
        if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
            const name = value.string(self.state, -1) orelse return self.invalid("gui.font.family must be a string");
            result.font.family.set(name) catch return self.invalid("gui.font.family must be valid UTF-8, without NUL, at most 256 bytes");
        }
        value.pop(self.state, 1);
        result.font.size = @floatCast(try self.number(.{ "size", 6, 96 }, result.font.size));
        result.font.line_height = @floatCast(try self.number(.{ "line_height", 0.75, 3 }, result.font.line_height));
        result.font.letter_spacing = @floatCast(try self.number(.{ "letter_spacing", -5, 20 }, result.font.letter_spacing));
        _ = lua_api.c.lua_getfield(self.state, -1, "thicken");
        if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
            if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TBOOLEAN) {
                return self.invalid("gui.font.thicken must be a boolean");
            }

            result.font.thicken = lua_api.c.lua_toboolean(self.state, -1) != 0;
        }
        value.pop(self.state, 1);
        const strength = try self.number(.{ "thicken_strength", 0, 255 }, @floatFromInt(result.font.thicken_strength));
        if (@trunc(strength) != strength) {
            return self.invalid("gui.font.thicken_strength must be an integer");
        }

        result.font.thicken_strength = @intFromFloat(strength);
    }
    value.pop(self.state, 1);

    _ = lua_api.c.lua_getfield(self.state, -1, "cursor");
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        try self.table("config.gui.cursor", &.{ "style", "blink", "blink_interval_ms" });
        _ = lua_api.c.lua_getfield(self.state, -1, "style");
        if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
            const name = value.string(self.state, -1) orelse return self.invalid("gui.cursor.style must be block, bar, underline or hollow");
            result.cursor.style = std.meta.stringToEnum(Cursor.Style, name) orelse return self.invalid("gui.cursor.style must be block, bar, underline or hollow");
        }
        value.pop(self.state, 1);
        _ = lua_api.c.lua_getfield(self.state, -1, "blink");
        if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
            if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TBOOLEAN) {
                return self.invalid("gui.cursor.blink must be a boolean");
            }

            result.cursor.blink = lua_api.c.lua_toboolean(self.state, -1) != 0;
        }
        value.pop(self.state, 1);
        const interval = try self.number(.{ "blink_interval_ms", 100, 5000 }, @floatFromInt(result.cursor.blink_interval_ms));
        if (@trunc(interval) != interval) {
            return self.invalid("gui.cursor.blink_interval_ms must be an integer");
        }

        result.cursor.blink_interval_ms = @intFromFloat(interval);
    }
    value.pop(self.state, 1);

    _ = lua_api.c.lua_getfield(self.state, -1, "window");
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        result.window = try self.window(result.window);
    }
    value.pop(self.state, 1);

    _ = lua_api.c.lua_getfield(self.state, -1, "chrome");
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        result.chrome = try self.chrome(result.chrome);
    }
    value.pop(self.state, 1);

    _ = lua_api.c.lua_getfield(self.state, -1, "sidebar");
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        result.sidebar = try self.sidebar(result.sidebar);
    }
    value.pop(self.state, 1);
    return result;
}

fn sidebar(self: Parser, initial: Sidebar) !Sidebar {
    try self.table("config.gui.sidebar", &.{"width"});
    var result = initial;
    result.width = @floatCast(try self.number(.{ "width", Sidebar.min_width, Sidebar.max_width }, result.width));
    return result;
}

fn chrome(self: Parser, initial: GuiChrome) !GuiChrome {
    try self.table("config.gui.chrome", &.{"scale"});
    var result = initial;
    result.scale = @floatCast(try self.number(.{ "scale", 0.5, 2 }, result.scale));
    return result;
}

fn window(self: Parser, initial: GuiWindow) !GuiWindow {
    try self.table("config.gui.window", &.{ "background_opacity", "background_blur", "titlebar", "padding" });
    var result = initial;
    result.background_opacity = @floatCast(try self.number(.{ "background_opacity", 0, 1 }, result.background_opacity));
    result.background_blur = try self.backgroundBlur(result.background_blur);
    _ = lua_api.c.lua_getfield(self.state, -1, "titlebar");
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TBOOLEAN) {
            return self.invalid("gui.window.titlebar must be a boolean");
        }

        result.titlebar = lua_api.c.lua_toboolean(self.state, -1) != 0;
    }
    value.pop(self.state, 1);

    _ = lua_api.c.lua_getfield(self.state, -1, "padding");
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNIL) {
        try self.table("config.gui.window.padding", &.{ "x", "y" });
        result.padding.x = @floatCast(try self.number(.{ "x", 0, 256 }, result.padding.x));
        result.padding.y = @floatCast(try self.number(.{ "y", 0, 256 }, result.padding.y));
    }
    value.pop(self.state, 1);
    return result;
}

fn backgroundBlur(self: Parser, initial: u8) !u8 {
    _ = lua_api.c.lua_getfield(self.state, -1, "background_blur");
    const legacy: ?bool = if (lua_api.c.lua_type(self.state, -1) == lua_api.c.LUA_TBOOLEAN) lua_api.c.lua_toboolean(self.state, -1) != 0 else null;
    value.pop(self.state, 1);
    if (legacy) |enabled| {
        // Existing boolean configs retain the default radius used by Ghostty.
        return if (enabled) 20 else 0;
    }

    const radius = try self.number(.{ "background_blur", 0, 255 }, @floatFromInt(initial));
    if (@trunc(radius) != radius) {
        return self.invalid("gui.window.background_blur must be an integer");
    }

    return @intFromFloat(radius);
}

fn table(self: Parser, path: []const u8, allowed: []const []const u8) !void {
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TTABLE) {
        self.diagnostic.set("{s} must be a table", .{path});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(self.state, .{ .index = -1, .allowed = allowed, .path = path }, self.diagnostic);
}

fn number(self: Parser, comptime spec: anytype, default: f64) !f64 {
    _ = lua_api.c.lua_getfield(self.state, -1, spec[0]);
    defer value.pop(self.state, 1);
    if (lua_api.c.lua_type(self.state, -1) == lua_api.c.LUA_TNIL) {
        return default;
    }

    const number_value = lua_api.c.lua_tonumberx(self.state, -1, null);
    if (lua_api.c.lua_type(self.state, -1) != lua_api.c.LUA_TNUMBER or !std.math.isFinite(number_value) or number_value < spec[1] or number_value > spec[2]) {
        self.diagnostic.set("gui.{s} must be a number in {d}..{d}", .{ spec[0], spec[1], spec[2] });
        return error.InvalidConfig;
    }

    return number_value;
}

fn invalid(self: Parser, message: []const u8) error{InvalidConfig} {
    self.diagnostic.set("{s}", .{message});
    return error.InvalidConfig;
}
