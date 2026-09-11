//! Bar value parsing independent of generation loading and callback registries.

const std = @import("std");
const core = @import("telar-core");
const lua = @import("lua-api").c;
const input = @import("../input/root.zig");
const bars = @import("../bars/root.zig");
const config_model = @import("model.zig");
const default_bindings = @import("default_bindings.zig");
const lua_value = @import("lua_value.zig");
const keybind = input.keybind;
const kitty = @import("../graphics/root.zig").kitty;
const icons = @import("../ui/root.zig").icons;

const Io = std.Io;
const ensureArrayOnly = lua_value.ensureArrayOnly;
const ensureOnlyFields = lua_value.ensureOnlyFields;
const integer = lua_value.integer;
const optionalIntegerField = lua_value.optionalIntegerField;
const optionalMebibytes = lua_value.optionalMebibytes;
const optionalMilliseconds = lua_value.optionalMilliseconds;
const optionalPositiveId = lua_value.optionalPositiveId;
const optionalStringField = lua_value.optionalStringField;
const pop = lua_value.pop;
const requiredIntegerField = lua_value.requiredIntegerField;
const requiredStringField = lua_value.requiredStringField;
const string = lua_value.string;

const Diagnostic = config_model.Diagnostic;

pub fn parseBarInterval(state: *lua.lua_State, index: c_int, diagnostic: *Diagnostic) !u64 {
    const absolute = lua.lua_absindex(state, index);
    _ = lua.lua_getfield(state, absolute, "every_ms");
    defer pop(state, 1);
    const value = if (lua.lua_type(state, -1) == lua.LUA_TNIL)
        1_000
    else
        integer(state, -1) orelse {
            diagnostic.set("bar every_ms must be an integer", .{});
            return error.InvalidConfig;
        };
    if (value < bars.min_interval_ms or value > bars.max_interval_ms) {
        diagnostic.set(
            "bar every_ms must be in {d}..{d}",
            .{ bars.min_interval_ms, bars.max_interval_ms },
        );
        return error.InvalidConfig;
    }

    return @as(u64, @intCast(value)) * std.time.ns_per_ms;
}

pub fn parseBarContent(state: *lua.lua_State, index: c_int, diagnostic: *Diagnostic) !bars.Content {
    const absolute = lua.lua_absindex(state, index);
    var content: bars.Content = .{};
    if (lua.lua_type(state, absolute) == lua.LUA_TNIL) {
        return content;
    }
    if (string(state, absolute)) |value| {
        content.append(.{ .text = value }) catch |err| {
            diagnostic.set("invalid bar text: {s}", .{@errorName(err)});
            return error.InvalidBarContent;
        };
        return content;
    }
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("bar render must return nil, text, a segment, or an array of segments", .{});
        return error.InvalidBarContent;
    }

    _ = lua.lua_getfield(state, absolute, "text");
    const has_text = lua.lua_type(state, -1) != lua.LUA_TNIL;
    pop(state, 1);
    _ = lua.lua_getfield(state, absolute, "icon");
    const has_icon = lua.lua_type(state, -1) != lua.LUA_TNIL;
    pop(state, 1);
    if (has_text or has_icon) {
        const segment = try parseBarSegment(state, absolute, diagnostic);
        content.append(.{ .text = segment.text, .icon = segment.icon, .style = segment.style }) catch |err| {
            diagnostic.set("invalid bar segment: {s}", .{@errorName(err)});
            return error.InvalidBarContent;
        };
        return content;
    }

    const count = lua.lua_rawlen(state, absolute);
    if (count > bars.max_segments) {
        diagnostic.set("bar content exceeds {d} segments", .{bars.max_segments});
        return error.InvalidBarContent;
    }
    try ensureArrayOnly(state, .{ .index = absolute, .count = count, .path = "bar content" }, diagnostic);
    for (0..count) |segment_index| {
        _ = lua.lua_geti(state, absolute, @intCast(segment_index + 1));
        const segment = parseBarSegment(state, -1, diagnostic) catch |err| {
            pop(state, 1);
            return err;
        };
        content.append(.{ .text = segment.text, .icon = segment.icon, .style = segment.style }) catch |err| {
            pop(state, 1);
            diagnostic.set("invalid bar segment {d}: {s}", .{ segment_index + 1, @errorName(err) });
            return error.InvalidBarContent;
        };
        pop(state, 1);
    }

    return content;
}

pub const ParsedBarSegment = @import("ParsedBarSegment.zig");

pub fn parseBarSegment(state: *lua.lua_State, index: c_int, diagnostic: *Diagnostic) !ParsedBarSegment {
    const absolute = lua.lua_absindex(state, index);
    if (string(state, absolute)) |value| {
        return .{ .text = value, .icon = null, .style = .{} };
    }
    if (lua.lua_type(state, absolute) != lua.LUA_TTABLE) {
        diagnostic.set("bar segment must be text or a table", .{});
        return error.InvalidBarContent;
    }

    try ensureOnlyFields(state, .{
        .index = absolute,
        .allowed = &.{ "text", "icon", "fg", "bg", "bold", "italic", "faint", "underline", "strikethrough" },
        .path = "bar segment",
    }, diagnostic);
    _ = lua.lua_getfield(state, absolute, "text");
    const text_value = if (lua.lua_type(state, -1) == lua.LUA_TNIL)
        ""
    else
        string(state, -1) orelse {
            pop(state, 1);
            diagnostic.set("bar segment text must be a string", .{});
            return error.InvalidBarContent;
        };
    pop(state, 1);

    _ = lua.lua_getfield(state, absolute, "icon");
    const icon_value: ?icons.Icon = if (lua.lua_type(state, -1) == lua.LUA_TNIL)
        null
    else icon: {
        const name = string(state, -1) orelse {
            pop(state, 1);
            diagnostic.set("bar segment icon must be a string", .{});
            return error.InvalidBarContent;
        };
        break :icon parseBarIcon(name) orelse {
            diagnostic.set("unknown bar icon '{s}'", .{name});
            pop(state, 1);
            return error.InvalidBarContent;
        };
    };
    pop(state, 1);

    var style: bars.Style = .{};
    inline for (.{ .{ "fg", "foreground" }, .{ "bg", "background" } }) |field| {
        _ = lua.lua_getfield(state, absolute, field[0]);
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            @field(style, field[1]) = try parseBarColor(state, -1, diagnostic);
        }
        pop(state, 1);
    }
    inline for (.{ "bold", "italic", "faint", "underline", "strikethrough" }) |field| {
        _ = lua.lua_getfield(state, absolute, field);
        if (lua.lua_type(state, -1) != lua.LUA_TNIL) {
            if (lua.lua_type(state, -1) != lua.LUA_TBOOLEAN) {
                pop(state, 1);
                diagnostic.set("bar segment {s} must be a boolean", .{field});
                return error.InvalidBarContent;
            }
            @field(style, field) = lua.lua_toboolean(state, -1) != 0;
        }
        pop(state, 1);
    }

    return .{ .text = text_value, .icon = icon_value, .style = style };
}

pub fn parseBarColor(state: *lua.lua_State, index: c_int, diagnostic: *Diagnostic) !bars.Color {
    if (integer(state, index)) |value| {
        if (value < 0 or value > 255) {
            diagnostic.set("bar color index must be in 0..255", .{});
            return error.InvalidBarContent;
        }

        return .{ .value = .{ .indexed = @intCast(value) } };
    }

    const name = string(state, index) orelse {
        diagnostic.set("bar color must be a palette name, #RRGGBB, default, or an index", .{});
        return error.InvalidBarContent;
    };
    if (std.ascii.eqlIgnoreCase(name, "default")) {
        return .{ .value = .default };
    }
    inline for (std.meta.fields(bars.PaletteColor)) |field| {
        if (normalizedNameEql(name, field.name)) {
            return .{ .palette = @enumFromInt(field.value) };
        }
    }
    if (name.len == 7 and name[0] == '#') {
        const value = std.fmt.parseInt(u24, name[1..], 16) catch {
            diagnostic.set("bar color '{s}' is not #RRGGBB", .{name});
            return error.InvalidBarContent;
        };
        return .{ .value = .{ .rgb = .{
            @intCast((value >> 16) & 0xff),
            @intCast((value >> 8) & 0xff),
            @intCast(value & 0xff),
        } } };
    }

    diagnostic.set("unknown bar color '{s}'", .{name});
    return error.InvalidBarContent;
}

pub fn parseBarIcon(name: []const u8) ?icons.Icon {
    inline for (std.meta.fields(icons.Icon)) |field| {
        if (normalizedNameEql(name, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return null;
}

pub fn normalizedNameEql(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) {
        return false;
    }
    for (left, right) |left_byte, right_byte| {
        const normalized_left = if (left_byte == '-') '_' else std.ascii.toLower(left_byte);
        const normalized_right = if (right_byte == '-') '_' else std.ascii.toLower(right_byte);
        if (normalized_left != normalized_right) {
            return false;
        }
    }

    return true;
}
