const std = @import("std");
const lua = @import("lua-api").c;
const value = @import("lua_value.zig");
const Diagnostic = @import("Diagnostic.zig");
const Config = @import("GuiConfig.zig");
const Cursor = @import("GuiCursor.zig");
const Sidebar = @import("GuiSidebar.zig");
const Parser = @This();

state: *lua.lua_State,
diagnostic: *Diagnostic,

/// Overlays validated native preferences on a config or profile snapshot.
/// Example: `snapshot.gui = try parser.parse(snapshot.gui);`
pub fn parse(parser: Parser, initial: Config) !Config {
    if (lua.lua_type(parser.state, -1) != lua.LUA_TTABLE) {
        return parser.invalid("config.gui must be a table");
    }

    _ = lua.lua_getfield(parser.state, -1, "theme");
    const old_theme = lua.lua_type(parser.state, -1) != lua.LUA_TNIL;
    value.pop(parser.state, 1);
    if (old_theme) {
        return parser.invalid("gui.theme moved to theme.terminal; select a preset once with theme = 'vesper'");
    }

    try parser.table("config.gui", &.{ "font", "cursor", "window", "chrome", "sidebar" });
    var result = initial;
    _ = lua.lua_getfield(parser.state, -1, "font");
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        try parser.table("config.gui.font", &.{ "family", "size", "line_height", "letter_spacing", "thicken", "thicken_strength" });
        _ = lua.lua_getfield(parser.state, -1, "family");
        if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
            const name = value.string(parser.state, -1) orelse return parser.invalid("gui.font.family must be a string");
            result.font.family.set(name) catch return parser.invalid("gui.font.family must be valid UTF-8, without NUL, at most 256 bytes");
        }
        value.pop(parser.state, 1);
        result.font.size = @floatCast(try parser.number(.{ "size", 6, 96 }, result.font.size));
        result.font.line_height = @floatCast(try parser.number(.{ "line_height", 0.75, 3 }, result.font.line_height));
        result.font.letter_spacing = @floatCast(try parser.number(.{ "letter_spacing", -5, 20 }, result.font.letter_spacing));
        _ = lua.lua_getfield(parser.state, -1, "thicken");
        if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(parser.state, -1) != lua.LUA_TBOOLEAN) {
                return parser.invalid("gui.font.thicken must be a boolean");
            }

            result.font.thicken = lua.lua_toboolean(parser.state, -1) != 0;
        }
        value.pop(parser.state, 1);
        const strength = try parser.number(.{ "thicken_strength", 0, 255 }, @floatFromInt(result.font.thicken_strength));
        if (@trunc(strength) != strength) {
            return parser.invalid("gui.font.thicken_strength must be an integer");
        }

        result.font.thicken_strength = @intFromFloat(strength);
    }
    value.pop(parser.state, 1);

    _ = lua.lua_getfield(parser.state, -1, "cursor");
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        try parser.table("config.gui.cursor", &.{ "style", "blink", "blink_interval_ms" });
        _ = lua.lua_getfield(parser.state, -1, "style");
        if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
            const name = value.string(parser.state, -1) orelse return parser.invalid("gui.cursor.style must be block, bar, underline or hollow");
            result.cursor.style = std.meta.stringToEnum(Cursor.Style, name) orelse return parser.invalid("gui.cursor.style must be block, bar, underline or hollow");
        }
        value.pop(parser.state, 1);
        _ = lua.lua_getfield(parser.state, -1, "blink");
        if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(parser.state, -1) != lua.LUA_TBOOLEAN) {
                return parser.invalid("gui.cursor.blink must be a boolean");
            }

            result.cursor.blink = lua.lua_toboolean(parser.state, -1) != 0;
        }
        value.pop(parser.state, 1);
        const interval = try parser.number(.{ "blink_interval_ms", 100, 5000 }, @floatFromInt(result.cursor.blink_interval_ms));
        if (@trunc(interval) != interval) {
            return parser.invalid("gui.cursor.blink_interval_ms must be an integer");
        }

        result.cursor.blink_interval_ms = @intFromFloat(interval);
    }
    value.pop(parser.state, 1);

    _ = lua.lua_getfield(parser.state, -1, "window");
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        result.window = try parser.window(result.window);
    }
    value.pop(parser.state, 1);

    _ = lua.lua_getfield(parser.state, -1, "chrome");
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        result.chrome = try parser.chrome(result.chrome);
    }
    value.pop(parser.state, 1);

    _ = lua.lua_getfield(parser.state, -1, "sidebar");
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        result.sidebar = try parser.sidebar(result.sidebar);
    }
    value.pop(parser.state, 1);
    return result;
}

fn sidebar(parser: Parser, initial: Sidebar) !Sidebar {
    try parser.table("config.gui.sidebar", &.{"width"});
    var result = initial;
    result.width = @floatCast(try parser.number(.{ "width", Sidebar.min_width, Sidebar.max_width }, result.width));
    return result;
}

fn chrome(parser: Parser, initial: @import("GuiChrome.zig")) !@import("GuiChrome.zig") {
    try parser.table("config.gui.chrome", &.{"scale"});
    var result = initial;
    result.scale = @floatCast(try parser.number(.{ "scale", 0.5, 2 }, result.scale));
    return result;
}

fn window(parser: Parser, initial: @import("GuiWindow.zig")) !@import("GuiWindow.zig") {
    try parser.table("config.gui.window", &.{ "background_opacity", "background_blur", "titlebar", "padding" });
    var result = initial;
    result.background_opacity = @floatCast(try parser.number(.{ "background_opacity", 0, 1 }, result.background_opacity));
    result.background_blur = try parser.backgroundBlur(result.background_blur);
    _ = lua.lua_getfield(parser.state, -1, "titlebar");
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        if (lua.lua_type(parser.state, -1) != lua.LUA_TBOOLEAN) {
            return parser.invalid("gui.window.titlebar must be a boolean");
        }

        result.titlebar = lua.lua_toboolean(parser.state, -1) != 0;
    }
    value.pop(parser.state, 1);

    _ = lua.lua_getfield(parser.state, -1, "padding");
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNIL) {
        try parser.table("config.gui.window.padding", &.{ "x", "y" });
        result.padding.x = @floatCast(try parser.number(.{ "x", 0, 256 }, result.padding.x));
        result.padding.y = @floatCast(try parser.number(.{ "y", 0, 256 }, result.padding.y));
    }
    value.pop(parser.state, 1);
    return result;
}

fn backgroundBlur(parser: Parser, initial: u8) !u8 {
    _ = lua.lua_getfield(parser.state, -1, "background_blur");
    const legacy: ?bool = if (lua.lua_type(parser.state, -1) == lua.LUA_TBOOLEAN) lua.lua_toboolean(parser.state, -1) != 0 else null;
    value.pop(parser.state, 1);
    if (legacy) |enabled| {
        // Existing boolean configs retain the default radius used by Ghostty.
        return if (enabled) 20 else 0;
    }

    const radius = try parser.number(.{ "background_blur", 0, 255 }, @floatFromInt(initial));
    if (@trunc(radius) != radius) {
        return parser.invalid("gui.window.background_blur must be an integer");
    }

    return @intFromFloat(radius);
}

fn table(parser: Parser, path: []const u8, allowed: []const []const u8) !void {
    if (lua.lua_type(parser.state, -1) != lua.LUA_TTABLE) {
        parser.diagnostic.set("{s} must be a table", .{path});
        return error.InvalidConfig;
    }

    try value.ensureOnlyFields(parser.state, .{ .index = -1, .allowed = allowed, .path = path }, parser.diagnostic);
}

fn number(parser: Parser, comptime spec: anytype, default: f64) !f64 {
    _ = lua.lua_getfield(parser.state, -1, spec[0]);
    defer value.pop(parser.state, 1);
    if (lua.lua_type(parser.state, -1) == lua.LUA_TNIL) {
        return default;
    }

    const number_value = lua.lua_tonumberx(parser.state, -1, null);
    if (lua.lua_type(parser.state, -1) != lua.LUA_TNUMBER or !std.math.isFinite(number_value) or number_value < spec[1] or number_value > spec[2]) {
        parser.diagnostic.set("gui.{s} must be a number in {d}..{d}", .{ spec[0], spec[1], spec[2] });
        return error.InvalidConfig;
    }

    return number_value;
}

fn invalid(parser: Parser, message: []const u8) error{InvalidConfig} {
    parser.diagnostic.set("{s}", .{message});
    return error.InvalidConfig;
}
