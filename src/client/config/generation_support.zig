//! Atomic client configuration generation and its compiled Lua callbacks.
const keyinput = @import("keyinput");

const data = @import("model");
const std = @import("std");
const lua_api = @import("lua-api");
const BarCallbackContext = @import("BarCallbackContext.zig");
const Callback = @import("Callback.zig");
const lua_value = @import("lua_value.zig");
const lua = @import("telar-lua");

pub const api_version: u16 = 2;

pub const max_binding_suffix_keys = data.config_values.max_binding_keys - 1;

pub const max_config_bytes = 1024 * 1024;

pub const max_profile_name_bytes = 64;

pub const bootstrap = @embedFile("bootstrap.lua");

pub fn validProfileName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_profile_name_bytes) {
        return false;
    }
    for (name) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    return true;
}

pub fn pushReadonlyContext(state: *lua_api.c.lua_State, context: data.CallbackContext) void {
    lua_api.c.lua_createtable(state, 0, 5);
    setBooleanField(state, .{ .index = -1, .name = "sidebar_visible" }, context.sidebar_visible);
    setIntegerField(state, .{ .index = -1, .name = "tab_count" }, context.tab_count);
    setIntegerField(state, .{ .index = -1, .name = "active_tab_index" }, @as(u32, context.active_tab_index) + 1);
    setIntegerField(state, .{ .index = -1, .name = "pane_count" }, context.pane_count);
    setIntegerField(state, .{ .index = -1, .name = "focused_pane_id" }, context.focused_pane_id);

    freezeTable(state);
}

pub fn pushReadonlyBarContext(state: *lua_api.c.lua_State, context: BarCallbackContext) void {
    lua_api.c.lua_createtable(state, 0, 9);
    setBooleanField(state, .{ .index = -1, .name = "sidebar_visible" }, context.client.sidebar_visible);
    setIntegerField(state, .{ .index = -1, .name = "tab_count" }, context.client.tab_count);
    setIntegerField(state, .{ .index = -1, .name = "active_tab_index" }, @as(u32, context.client.active_tab_index) + 1);
    setIntegerField(state, .{ .index = -1, .name = "pane_count" }, context.client.pane_count);
    setIntegerField(state, .{ .index = -1, .name = "focused_pane_id" }, context.client.focused_pane_id);

    lua_api.c.lua_createtable(state, 0, 8);
    setIntegerField(state, .{ .index = -1, .name = "unix_seconds" }, context.time.unix_seconds);
    setIntegerField(state, .{ .index = -1, .name = "year" }, context.time.year);
    setIntegerField(state, .{ .index = -1, .name = "month" }, context.time.month);
    setIntegerField(state, .{ .index = -1, .name = "day" }, context.time.day);
    setIntegerField(state, .{ .index = -1, .name = "hour" }, context.time.hour);
    setIntegerField(state, .{ .index = -1, .name = "minute" }, context.time.minute);
    setIntegerField(state, .{ .index = -1, .name = "second" }, context.time.second);
    setIntegerField(state, .{ .index = -1, .name = "weekday" }, context.time.weekday);
    freezeTable(state);
    lua_api.c.lua_setfield(state, -2, "time");

    lua_api.c.lua_createtable(state, 0, 4);
    setBooleanField(state, .{ .index = -1, .name = "available" }, context.metrics != null);
    if (context.metrics) |metrics| {
        setIntegerField(state, .{ .index = -1, .name = "cpu_percent" }, metrics.cpu_percent);
        setIntegerField(state, .{ .index = -1, .name = "memory_used_decigib" }, metrics.memory_used_decigib);
        if (metrics.battery_percent) |battery| {
            setIntegerField(state, .{ .index = -1, .name = "battery_percent" }, battery);
        }
    }
    freezeTable(state);
    lua_api.c.lua_setfield(state, -2, "metrics");

    if (context.command_output) |output| {
        _ = lua_api.c.lua_pushlstring(state, output.ptr, output.len);
        lua_api.c.lua_setfield(state, -2, "output");
    }

    _ = lua_api.c.lua_pushlstring(state, context.pane_title.ptr, context.pane_title.len);
    lua_api.c.lua_setfield(state, -2, "pane_title");

    freezeTable(state);
}

/// Appends one optional string array of a manifest entry to its bounded list.
pub fn hasControlBytes(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return true;
        }
    }
    return false;
}

fn freezeTable(state: *lua_api.c.lua_State) void {
    lua_api.c.lua_createtable(state, 0, 0);
    lua_api.c.lua_createtable(state, 0, 3);
    lua_api.c.lua_pushvalue(state, -3);
    lua_api.c.lua_setfield(state, -2, "__index");
    lua_api.c.lua_pushcclosure(state, readonlyNewIndex, 0);
    lua_api.c.lua_setfield(state, -2, "__newindex");
    lua_api.c.lua_pushboolean(state, 0);
    lua_api.c.lua_setfield(state, -2, "__metatable");
    _ = lua_api.c.lua_setmetatable(state, -2);
    lua_api.c.lua_remove(state, -2);
}

fn setBooleanField(state: *lua_api.c.lua_State, target: FieldTarget, value: bool) void {
    const absolute = lua_api.c.lua_absindex(state, target.index);
    lua_api.c.lua_pushboolean(state, @intFromBool(value));
    lua_api.c.lua_setfield(state, absolute, target.name);
}

fn setIntegerField(state: *lua_api.c.lua_State, target: FieldTarget, value: anytype) void {
    const absolute = lua_api.c.lua_absindex(state, target.index);
    lua_api.c.lua_pushinteger(state, @intCast(value));
    lua_api.c.lua_setfield(state, absolute, target.name);
}

fn readonlyNewIndex(state: ?*lua_api.c.lua_State) callconv(.c) c_int {
    _ = lua_api.c.lua_pushstring(state.?, "callback context is immutable");
    return lua_api.c.lua_error(state.?);
}

pub fn parseInputDecision(state: *lua_api.c.lua_State, input_decision: DecisionInput, diagnostic: *data.Diagnostic) !data.InputDecision {
    const absolute = lua_api.c.lua_absindex(state, input_decision.index);
    if (lua_api.c.lua_type(state, absolute) != lua_api.c.LUA_TTABLE) {
        diagnostic.set("Lua expression must return a telar.input value", .{});
        return error.InvalidExpressionResult;
    }
    const kind = try lua_value.requiredStringField(state, .{ .index = absolute, .name = "input_kind" }, diagnostic);
    if (std.mem.eql(u8, kind, "consume")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{"input_kind"}, .path = "input decision" }, diagnostic);
        return .consume;
    }
    if (std.mem.eql(u8, kind, "forward")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{"input_kind"}, .path = "input decision" }, diagnostic);
        var keys: data.InputKeys = .{};
        @memcpy(keys.items[0..input_decision.callback.trigger_len], input_decision.callback.trigger[0..input_decision.callback.trigger_len]);
        keys.len = input_decision.callback.trigger_len;
        return .{ .forward_binding = keys };
    }
    if (std.mem.eql(u8, kind, "keys")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "input_kind", "keys" }, .path = "input decision" }, diagnostic);
        _ = lua_api.c.lua_getfield(state, absolute, "keys");
        defer lua_value.pop(state, 1);
        if (lua_api.c.lua_type(state, -1) != lua_api.c.LUA_TTABLE) {
            diagnostic.set("input decision keys must be an array", .{});
            return error.InvalidExpressionResult;
        }
        const count = lua_api.c.lua_rawlen(state, -1);
        if (count == 0 or count > data.effects.max_expression_keys) {
            diagnostic.set("input decision must contain 1..{d} keys", .{data.effects.max_expression_keys});
            return error.InvalidExpressionResult;
        }
        var keys: data.InputKeys = .{};
        for (0..count) |key_index| {
            _ = lua_api.c.lua_geti(state, -1, @intCast(key_index + 1));
            const value = lua_value.string(state, -1) orelse {
                lua_value.pop(state, 1);
                diagnostic.set("input decision key {d} must be a string", .{key_index + 1});
                return error.InvalidExpressionResult;
            };
            keys.items[key_index] = keyinput.chord.parseKey(value) catch |err| {
                diagnostic.set("invalid input decision key {d}: {s}", .{ key_index + 1, @errorName(err) });
                lua_value.pop(state, 1);
                return error.InvalidExpressionResult;
            };
            lua_value.pop(state, 1);
        }
        keys.len = @intCast(count);
        return .{ .keys = keys };
    }
    if (std.mem.eql(u8, kind, "paste")) {
        try lua_value.ensureOnlyFields(state, .{ .index = absolute, .allowed = &.{ "input_kind", "text" }, .path = "input decision" }, diagnostic);
        _ = lua_api.c.lua_getfield(state, absolute, "text");
        defer lua_value.pop(state, 1);
        const value = lua_value.string(state, -1) orelse {
            diagnostic.set("input decision paste text must be a string", .{});
            return error.InvalidExpressionResult;
        };
        if (value.len > data.effects.max_expression_paste_bytes) {
            diagnostic.set("input decision paste exceeds {d} bytes", .{data.effects.max_expression_paste_bytes});
            return error.InvalidExpressionResult;
        }
        var paste: data.InputPaste = .{};
        @memcpy(paste.bytes[0..value.len], value);
        paste.len = @intCast(value.len);
        return .{ .paste = paste };
    }
    diagnostic.set("unknown input decision '{s}'", .{kind});
    return error.InvalidExpressionResult;
}

const DecisionInput = struct {
    index: c_int,
    callback: *const Callback,
};

const FieldTarget = struct {
    index: c_int,
    name: [*:0]const u8,
};
