//! Bar value parsing independent of generation loading and callback registries.

const data = @import("model");
const lua_api = @import("lua-api");
const lua_value = @import("lua_value.zig");
const std = @import("std");

pub fn parseBarInterval(state: *lua_api.c.lua_State, index: c_int, diagnostic: *data.Diagnostic) !u64 {
    const absolute = lua_api.c.lua_absindex(state, index);
    _ = lua_api.c.lua_getfield(state, absolute, "every_ms");
    defer lua_value.pop(state, 1);
    const value = if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL)
        1_000
    else
        lua_value.integer(state, -1) orelse {
            diagnostic.set("bar every_ms must be an integer", .{});
            return error.InvalidConfig;
        };
    if (value < data.bar_values.min_interval_ms or value > data.bar_values.max_interval_ms) {
        diagnostic.set(
            "bar every_ms must be in {d}..{d}",
            .{ data.bar_values.min_interval_ms, data.bar_values.max_interval_ms },
        );
        return error.InvalidConfig;
    }

    return @as(u64, @intCast(value)) * std.time.ns_per_ms;
}

pub fn parseBarContent(state: *lua_api.c.lua_State, index: c_int, diagnostic: *data.Diagnostic) !data.Content {
    const absolute = lua_api.c.lua_absindex(state, index);
    var content: data.Content = .{};
    if (lua_api.c.lua_type(state, absolute) == lua_api.c.LUA_TNIL) {
        return content;
    }
    if (lua_value.string(state, absolute)) |value| {
        content.append(.{ .text = value }) catch |err| {
            diagnostic.set("invalid bar text: {s}", .{@errorName(err)});
            return error.InvalidBarContent;
        };
        return content;
    }
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("bar render must return nil, text, a segment, or an array of segments", .{});
        return error.InvalidBarContent;
    }

    _ = lua_api.c.lua_getfield(state, absolute, "text");
    const has_text = lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL;
    lua_value.pop(state, 1);
    _ = lua_api.c.lua_getfield(state, absolute, "icon");
    const has_icon = lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL;
    lua_value.pop(state, 1);
    if (has_text or has_icon) {
        const segment = try parseBarSegment(state, absolute, diagnostic);
        content.append(.{ .text = segment.text, .icon = segment.icon, .style = segment.style }) catch |err| {
            diagnostic.set("invalid bar segment: {s}", .{@errorName(err)});
            return error.InvalidBarContent;
        };
        return content;
    }

    const count = lua_api.c.lua_rawlen(state, absolute);
    if (count > data.bar_values.max_segments) {
        diagnostic.set("bar content exceeds {d} segments", .{data.bar_values.max_segments});
        return error.InvalidBarContent;
    }
    try lua_value.ensureArrayOnly(state, .{ .index = absolute, .count = count, .path = "bar content" }, diagnostic);
    for (0..count) |segment_index| {
        _ = lua_api.c.lua_geti(state, absolute, @intCast(segment_index + 1));
        const segment = parseBarSegment(state, -1, diagnostic) catch |err| {
            lua_value.pop(state, 1);
            return err;
        };
        content.append(.{ .text = segment.text, .icon = segment.icon, .style = segment.style }) catch |err| {
            lua_value.pop(state, 1);
            diagnostic.set("invalid bar segment {d}: {s}", .{ segment_index + 1, @errorName(err) });
            return error.InvalidBarContent;
        };
        lua_value.pop(state, 1);
    }

    return content;
}

pub fn parseBarSegment(state: *lua_api.c.lua_State, index: c_int, diagnostic: *data.Diagnostic) !ParsedBarSegment {
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_value.string(state, absolute)) |value| {
        return .{ .text = value, .icon = null, .style = .{} };
    }
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("bar segment must be text or a table", .{});
        return error.InvalidBarContent;
    }

    try lua_value.ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "text", "icon", "fg", "bg", "bold", "italic", "faint", "underline", "strikethrough" },
        .path = "bar segment",
    }, diagnostic);
    _ = lua_api.c.lua_getfield(state, absolute, "text");
    const text_value = if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL)
        ""
    else
        lua_value.string(state, -1) orelse {
            lua_value.pop(state, 1);
            diagnostic.set("bar segment text must be a string", .{});
            return error.InvalidBarContent;
        };
    lua_value.pop(state, 1);

    _ = lua_api.c.lua_getfield(state, absolute, "icon");
    const icon_value: ?data.icons.Icon = if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL)
        null
    else icon: {
        const name = lua_value.string(state, -1) orelse {
            lua_value.pop(state, 1);
            diagnostic.set("bar segment icon must be a string", .{});
            return error.InvalidBarContent;
        };
        break :icon parseBarIcon(name) orelse {
            diagnostic.set("unknown bar icon '{s}'", .{name});
            lua_value.pop(state, 1);
            return error.InvalidBarContent;
        };
    };
    lua_value.pop(state, 1);

    const style = try parseStyle(state, absolute, diagnostic);

    return .{ .text = text_value, .icon = icon_value, .style = style };
}

/// Reads the legacy `fg`, `bg` and emphasis fields of a segment or label.
/// Example: `const style = try bar_values.parseStyle(state, index, diagnostic);`
pub fn parseStyle(state: *lua_api.c.lua_State, index: c_int, diagnostic: *data.Diagnostic) !data.Style {
    const absolute = lua_api.c.lua_absindex(state, index);
    var style: data.Style = .{};
    inline for (.{ .{ "fg", "foreground" }, .{ "bg", "background" } }) |field| {
        _ = lua_api.c.lua_getfield(state, absolute, field[0]);
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
            @field(style, field[1]) = try parseBarColor(state, -1, diagnostic);
        }
        lua_value.pop(state, 1);
    }
    inline for (.{ "bold", "italic", "faint", "underline", "strikethrough" }) |field| {
        _ = lua_api.c.lua_getfield(state, absolute, field);
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TNIL) {
            if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TBOOLEAN) {
                lua_value.pop(state, 1);
                diagnostic.set("bar segment {s} must be a boolean", .{field});
                return error.InvalidBarContent;
            }
            @field(style, field) = lua_api.c.lua_toboolean(state, -1) != 0;
        }
        lua_value.pop(state, 1);
    }

    return style;
}

pub fn parseBarColor(state: *lua_api.c.lua_State, index: c_int, diagnostic: *data.Diagnostic) !data.bar_values.Color {
    if (lua_value.integer(state, index)) |value| {
        if (value < 0 or value > 255) {
            diagnostic.set("bar color index must be in 0..255", .{});
            return error.InvalidBarContent;
        }

        return .{ .value = .indexed(@intCast(value)) };
    }

    const name = lua_value.string(state, index) orelse {
        diagnostic.set("bar color must be a palette name, #RRGGBB, default, or an index", .{});
        return error.InvalidBarContent;
    };
    if (data.color_name.parse(name)) |color| {
        return color;
    }

    if (name.len == 7 and name[0] == '#') {
        diagnostic.set("bar color '{s}' is not #RRGGBB", .{name});
        return error.InvalidBarContent;
    }

    diagnostic.set("unknown bar color '{s}'", .{name});
    return error.InvalidBarContent;
}

pub fn parseBarIcon(name: []const u8) ?data.icons.Icon {
    inline for (std.meta.fields(data.icons.Icon)) |field| {
        if (normalizedNameEql(name, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return null;
}

pub fn normalizedNameEql(left: []const u8, right: []const u8) bool {
    return data.color_name.roleNameEql(left, right);
}

const ParsedBarSegment = struct {
    text: []const u8,
    icon: ?data.icons.Icon,
    style: data.Style,
};
