//! Converts the options a pick's `items` table, or its `items` function,
//! returns into bounded `PickItems`. An option is a string, or a table with
//! `label` and optional `value` and `detail`.
const data = @import("model");
const cellgrid = @import("cellgrid");
const std = @import("std");
const lua_api = @import("lua-api");
const lua_value = @import("lua_value.zig");

/// Replaces `items` with the list at `index`. Options past the list's
/// limits are left out or cut (`PickItems.keep`) and `items.reaches` names
/// the limits passed; an invalid option rejects the whole list.
///
/// ```zig
/// try pick_values.parse(state, -1, &items, diagnostic);
/// ```
pub fn parse(state: *lua_api.c.lua_State, index: c_int, items: *data.PickItems, diagnostic: *data.Diagnostic) !void {
    const absolute = lua_api.c.lua_absindex(state, index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("pick items must be a list of strings or {{ label, value, detail }} tables", .{});
        return error.InvalidPickItems;
    }

    const count = lua_api.c.lua_rawlen(state, absolute);
    try lua_value.ensureArrayOnly(
        state,
        .{
            .index = absolute,
            .count = count,
            .path = "pick items",
        },
        diagnostic,
    );
    items.clear();
    for (1..count + 1) |position| {
        _ = lua_api.c.lua_rawgeti(state, absolute, @intCast(position));
        defer lua_value.pop(state, 1);
        const item = try read(state, position, diagnostic);
        items.keep(item) catch |err| {
            diagnostic.set("pick item {d} is invalid: {s}", .{ position, @errorName(err) });
            return err;
        };
    }
}

// Reads the option on top of the stack. Its strings stay valid while the
// option is on the stack, and `append` copies them before it is popped.
fn read(state: *lua_api.c.lua_State, position: usize, diagnostic: *data.Diagnostic) !data.PickItem {
    if (lua_value.string(state, -1)) |label| {
        return .{ .label = label };
    }

    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("pick item {d} must be a string or a {{ label, value, detail }} table", .{position});
        return error.InvalidPickItems;
    }

    try lua_value.ensureOnlyFields(
        state,
        .{
            .index = -1,
            .allowed = &.{ "label", "value", "detail", "selected", "swatch" },
            .path = "pick item",
        },
        diagnostic,
    );
    const label = field(state, "label") orelse {
        diagnostic.set("pick item {d} needs a string label", .{position});
        return error.InvalidPickItems;
    };
    const value = field(state, "value");
    const detail = field(state, "detail");
    if (!absentOrString(state, "value") or !absentOrString(state, "detail")) {
        diagnostic.set("pick item {d} value and detail must be strings", .{position});
        return error.InvalidPickItems;
    }

    return .{
        .label = label,
        .value = value,
        .detail = detail orelse "",
        .selected = try selected(state, diagnostic),
        .swatch = try swatch(state, diagnostic),
    };
}

// A string field of the table on top of the stack. The table keeps the
// string alive after the field is popped.
fn field(state: *lua_api.c.lua_State, name: [*:0]const u8) ?[]const u8 {
    _ = lua_api.c.lua_getfield(state, -1, name);
    defer lua_value.pop(state, 1);
    return lua_value.string(state, -1);
}

fn absentOrString(state: *lua_api.c.lua_State, name: [*:0]const u8) bool {
    _ = lua_api.c.lua_getfield(state, -1, name);
    defer lua_value.pop(state, 1);
    const kind = lua_api.c.lua_type(state, -1);
    return kind == lua_api.c.LUA_TNIL or kind == lua_api.c.LUA_TSTRING;
}

fn selected(state: *lua_api.c.lua_State, diagnostic: *data.Diagnostic) !bool {
    _ = lua_api.c.lua_getfield(state, -1, "selected");
    defer lua_value.pop(state, 1);
    const kind = lua_api.c.lua_type(state, -1);
    if (kind != lua_api.c.LUA_TNIL and kind != lua_api.c.LUA_TBOOLEAN) {
        diagnostic.set("pick item selected must be a boolean", .{});
        return error.InvalidPickItems;
    }

    return lua_api.c.lua_toboolean(state, -1) != 0;
}

fn swatch(state: *lua_api.c.lua_State, diagnostic: *data.Diagnostic) !?[3]cellgrid.Color {
    _ = lua_api.c.lua_getfield(state, -1, "swatch");
    defer lua_value.pop(state, 1);
    if (lua_api.c.lua_type(state, -1) == lua_api.c.LUA_TNIL) {
        return null;
    }

    if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE or lua_api.c.lua_rawlen(state, -1) != 3) {
        diagnostic.set("pick item swatch must contain three #RRGGBB colors", .{});
        return error.InvalidPickItems;
    }

    lua_value.ensureArrayOnly(state, .{ .index = -1, .count = 3, .path = "pick item swatch" }, diagnostic) catch return error.InvalidPickItems;
    var result: [3]cellgrid.Color = undefined;
    for (&result, 1..) |*color, index| {
        _ = lua_api.c.lua_rawgeti(state, -1, @intCast(index));
        defer lua_value.pop(state, 1);
        const text = lua_value.string(state, -1) orelse "";
        if (text.len != 7 or text[0] != '#') {
            diagnostic.set("pick item swatch colors must be #RRGGBB", .{});
            return error.InvalidPickItems;
        }

        for (text[1..]) |byte| {
            if (!std.ascii.isHex(byte)) {
                diagnostic.set("pick item swatch colors must be #RRGGBB", .{});
                return error.InvalidPickItems;
            }
        }

        const rgb = std.fmt.parseInt(u24, text[1..], 16) catch {
            diagnostic.set("pick item swatch colors must be #RRGGBB", .{});
            return error.InvalidPickItems;
        };
        color.* = .rgb(.{ @intCast(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb) });
    }

    return result;
}
