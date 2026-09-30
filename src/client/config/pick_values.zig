//! Converts the options a pick's `items` table, or its `items` function,
//! returns into bounded `PickItems`. An option is a string, or a table with
//! `label` and optional `value` and `detail`.
const data = @import("model");
const lua_api = @import("lua-api");
const lua_value = @import("lua_value.zig");

/// Replaces `items` with the list at `index`; a rejected option rejects the
/// whole list.
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
    if (count > data.PickItems.max_items) {
        diagnostic.set("pick items hold at most {d} options, got {d}", .{ data.PickItems.max_items, count });
        return error.TooManyPickItems;
    }

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
        items.append(item) catch |err| {
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
            .allowed = &.{ "label", "value", "detail" },
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
