//! Atomic client configuration generation and its compiled Lua callbacks.

const config_model = @import("model.zig");
const std = @import("std");
const lua_api = @import("lua-api");
const CallbackContext = @import("CallbackContext.zig");
const BarCallbackContext = @import("BarCallbackContext.zig");
const FieldTarget = @import("FieldTarget.zig");
const DecisionInput = @import("DecisionInput.zig");
const Diagnostic = @import("Diagnostic.zig");
const InputDecision = @import("effects.zig").InputDecision;
const lua_value = @import("lua_value.zig");
const InputKeys = @import("InputKeys.zig");
const max_expression_keys = @import("effects.zig").max_expression_keys;
const parseKey_module = @import("../input/chord.zig").parseKey;
const max_expression_paste_bytes = @import("effects.zig").max_expression_paste_bytes;
const InputPaste = @import("InputPaste.zig");
const Generation = @import("Generation.zig");
const ThemeType = @import("../layout/icons.zig").Theme;
const SidebarRenderingType = @import("sidebar_rendering.zig").SidebarRendering;
const ColorType = @import("telar-core").Color;
const ActionType = @import("../input/action.zig").Action;
const NotificationLevelType = @import("telar-core").NotificationLevel;
const PaneIdType = @import("telar-core").PaneId;
const KeyType = @import("../input/Key.zig");
const IconType = @import("../layout/icons.zig").Icon;
const ClientColor = @import("../bars/model.zig").Color;
const max_intercept_hosts = @import("telar-core").max_intercept_hosts;
const orderHostname_module = @import("telar-core").orderHostname;
const default_bindings = @import("default_bindings.zig");
const first_custom_agent_provider_module = @import("telar-core").first_custom_agent_provider;
const StatusType = @import("telar-core").Status;
const AgentProviderType = @import("telar-core").AgentProvider;
const max_agent_session_title_bytes = @import("telar-core").max_agent_session_title_bytes;
const AgentAttachmentMarkers = @import("telar-core").AgentAttachmentMarkers;
const Delivery = @import("../notifications/notifications.zig").Delivery;
const theme_mod = @import("../appearance/theme_support.zig");

pub const api_version: u16 = 2;

pub const max_binding_suffix_keys = config_model.max_binding_keys - 1;

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

pub fn pushReadonlyContext(state: *lua_api.c.lua_State, context: CallbackContext) void {
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

pub fn parseInputDecision(state: *lua_api.c.lua_State, input_decision: DecisionInput, diagnostic: *Diagnostic) !InputDecision {
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
        var keys: InputKeys = .{};
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
        if (count == 0 or count > max_expression_keys) {
            diagnostic.set("input decision must contain 1..{d} keys", .{max_expression_keys});
            return error.InvalidExpressionResult;
        }
        var keys: InputKeys = .{};
        for (0..count) |key_index| {
            _ = lua_api.c.lua_geti(state, -1, @intCast(key_index + 1));
            const value = lua_value.string(state, -1) orelse {
                lua_value.pop(state, 1);
                diagnostic.set("input decision key {d} must be a string", .{key_index + 1});
                return error.InvalidExpressionResult;
            };
            keys.items[key_index] = parseKey_module(value) catch |err| {
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
        if (value.len > max_expression_paste_bytes) {
            diagnostic.set("input decision paste exceeds {d} bytes", .{max_expression_paste_bytes});
            return error.InvalidExpressionResult;
        }
        var paste: InputPaste = .{};
        @memcpy(paste.bytes[0..value.len], value);
        paste.len = @intCast(value.len);
        return .{ .paste = paste };
    }
    diagnostic.set("unknown input decision '{s}'", .{kind});
    return error.InvalidExpressionResult;
}

test "local module loader rejects oversized roots before copying" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.NameTooLong, Generation.loadSource(.{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .diagnostic = &diagnostic,
    }, .{
        .source = "return {}",
        .source_name = "@test.lua",
        .number = 1,
        .config_dir = "a" ** (std.fs.max_path_bytes + 1),
    }));
}

test "client config compiles theme, bindings, and callbacks" {
    const source =
        \\local telar = require("telar")
        \\local config = telar.config({ api_version = 2 })
        \\config.client = {
        \\  prefix = "ctrl+s",
        \\  icons = "nerd-font",
        \\  theme = telar.theme({
        \\    base = "vesper",
        \\    colors = { accent = "#010203" },
        \\  }),
        \\  sidebar = { visible = false, renderer = "cells" },
        \\  pane_gaps = false,
        \\  sound = { enabled = true, ready = false, needs_input = true },
        \\  input = { escape_timeout_ms = 40, sequence_timeout_ms = 750 },
        \\  keybindings = {
        \\    telar.bind({ "%" }, telar.action.split_pane({ direction = "horizontal" })),
        \\    telar.bind({ "g" }, function(ctx)
        \\      return telar.action.toggle_sidebar()
        \\    end),
        \\    telar.bind_global({ "ctrl+g" }, telar.action.detach()),
        \\    telar.bind({ "R" }, telar.action.resize_pane({ direction = "right" })),
        \\    telar.bind({ "z" }, telar.action.toggle_pane_fullscreen()),
        \\    telar.bind({ "S" }, telar.action.resize_sidebar({ direction = "left" })),
        \\    telar.bind_global({ "ctrl+h" }, telar.action.navigate_pane({ direction = "left" })),
        \\  },
        \\}
        \\return config
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 7 });
    defer generation.deinit();
    try std.testing.expectEqual(@as(u16, 7), generation.snapshot.binding_count);
    try std.testing.expectEqual(@as(u16, 1), generation.callback_count);
    try std.testing.expect(!generation.snapshot.sidebar_visible);
    try std.testing.expect(!generation.snapshot.pane_gaps);
    try std.testing.expect(generation.snapshot.sound.enabled);
    try std.testing.expect(!generation.snapshot.sound.ready);
    try std.testing.expect(generation.snapshot.sound.needs_input);
    try std.testing.expectEqual(ThemeType.nerd_font, generation.snapshot.icon_theme);
    try std.testing.expectEqual(SidebarRenderingType.cells, generation.snapshot.sidebar_rendering);
    try std.testing.expectEqual(@as(u64, 40 * std.time.ns_per_ms), generation.snapshot.input_escape_timeout_ns);
    try std.testing.expectEqual(@as(u64, 750 * std.time.ns_per_ms), generation.snapshot.input_sequence_timeout_ns);
    try std.testing.expectEqualDeep(
        ColorType{ .rgb = .{ 1, 2, 3 } },
        generation.snapshot.theme.palette.accent,
    );
    try std.testing.expectEqualDeep(
        ActionType{ .split_pane = .horizontal },
        generation.snapshot.bindings[0].action,
    );
    try std.testing.expectEqualDeep(
        ActionType{ .lua_callback = .{ .generation = 7, .id = 0 } },
        generation.snapshot.bindings[1].action,
    );
    const ctrl_s = try parseKey_module("ctrl+s");
    try std.testing.expectEqualDeep(ctrl_s, generation.snapshot.prefix);
    try std.testing.expectEqualDeep(ctrl_s, generation.snapshot.bindings[0].keys[0]);
    try std.testing.expectEqualDeep(try parseKey_module("%"), generation.snapshot.bindings[0].keys[1]);
    try std.testing.expectEqual(@as(u8, 2), generation.snapshot.bindings[0].len);
    try std.testing.expectEqualDeep(ctrl_s, generation.snapshot.bindings[1].keys[0]);
    try std.testing.expectEqualDeep(try parseKey_module("g"), generation.snapshot.bindings[1].keys[1]);
    try std.testing.expectEqualDeep(try parseKey_module("ctrl+g"), generation.snapshot.bindings[2].keys[0]);
    try std.testing.expectEqual(@as(u8, 1), generation.snapshot.bindings[2].len);
    try std.testing.expectEqual(ActionType.detach, generation.snapshot.bindings[2].action);
    try std.testing.expectEqualDeep(
        ActionType{ .resize_pane = .right },
        generation.snapshot.bindings[3].action,
    );
    try std.testing.expectEqual(
        ActionType.toggle_pane_fullscreen,
        generation.snapshot.bindings[4].action,
    );
    try std.testing.expectEqualDeep(
        ActionType{ .resize_sidebar = .left },
        generation.snapshot.bindings[5].action,
    );
    try std.testing.expectEqualDeep(
        ActionType{ .navigate_pane = .left },
        generation.snapshot.bindings[6].action,
    );
}

test "focused scroll Lua actions compile for global and prefixed bindings" {
    const source =
        \\local telar = require("telar")
        \\return { api_version = 2, client = { keybindings = {
        \\  telar.bind_global({ "alt+up" }, telar.action.scroll_pane({ direction = "up" })),
        \\  telar.bind({ "=" }, telar.action.scroll_pane({ direction = "down" })),
        \\} } }
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();

    try std.testing.expectEqual(@as(u16, 2), generation.snapshot.binding_count);
    try std.testing.expectEqualDeep(ActionType{ .scroll_pane = .up }, generation.snapshot.bindings[0].action);
    try std.testing.expectEqualDeep(ActionType{ .scroll_pane = .down }, generation.snapshot.bindings[1].action);
    try std.testing.expectEqual(@as(u8, 1), generation.snapshot.bindings[0].len);
    try std.testing.expectEqualDeep(try parseKey_module("alt+up"), generation.snapshot.bindings[0].keys[0]);
    try std.testing.expectEqual(@as(u8, 2), generation.snapshot.bindings[1].len);
    try std.testing.expectEqualDeep(generation.snapshot.prefix, generation.snapshot.bindings[1].keys[0]);
}

test "focused scroll Lua actions reject invalid directions and unknown fields" {
    inline for (.{
        "{ kind = 'scroll-pane', direction = 'left' }",
        "{ kind = 'scroll-pane' }",
        "{ kind = 'scroll-pane', direction = 1 }",
        "{ kind = 'scroll-pane', direction = 'up', rows = 3 }",
    }) |action_source| {
        const source = "local telar = require('telar')\nreturn { api_version = 2, client = { keybindings = { telar.bind({ 's' }, " ++ action_source ++ ") } } }";
        var diagnostic: Diagnostic = .{};

        try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 1 }));
        try std.testing.expect(diagnostic.message().len != 0);
    }
}

test "history palette Lua action constructor compiles" {
    const source =
        \\local telar = require("telar")
        \\return { api_version = 2, client = { keybindings = {
        \\  telar.bind_global({ "ctrl+r" }, telar.action.history_palette()),
        \\} } }
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();

    try std.testing.expectEqual(@as(u16, 1), generation.snapshot.binding_count);
    try std.testing.expectEqualDeep(
        try parseKey_module("ctrl+r"),
        generation.snapshot.bindings[0].keys[0],
    );
    try std.testing.expectEqual(@as(u8, 1), generation.snapshot.bindings[0].len);
    try std.testing.expectEqual(
        ActionType.history_palette,
        generation.snapshot.bindings[0].action,
    );
}

test "client config rejects an incompatible API version" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.IncompatibleConfigApi,
        Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 1 }", .source_name = "@config.lua", .number = 1 }),
    );
    try std.testing.expectEqualStrings(
        "config.api_version is 1; this Telar accepts 2",
        diagnostic.message(),
    );
}

test "client config rejects non-boolean pane gaps" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { pane_gaps = 0 } }", .source_name = "@config.lua", .number = 1 }),
    );
    try std.testing.expectEqualStrings(
        "config.client.pane_gaps must be a boolean",
        diagnostic.message(),
    );
}

test "client config rejects non-boolean sound settings" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { sound = { ready = 1 } } }", .source_name = "@config.lua", .number = 1 }),
    );
    try std.testing.expectEqualStrings(
        "config.client.sound.ready must be a boolean",
        diagnostic.message(),
    );
}

test "client config rejects an unknown icon theme" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { icons = 'emoji' } }", .source_name = "@config.lua", .number = 1 }),
    );
    try std.testing.expectEqualStrings(
        "unknown config.client.icons: emoji",
        diagnostic.message(),
    );
}

test "client config rejects invalid prefixes" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { prefix = 'ctrl' } }", .source_name = "@config.lua", .number = 1 }),
    );
    try std.testing.expectEqualStrings(
        "invalid config.client.prefix: MissingKey",
        diagnostic.message(),
    );
}

test "client config rejects invalid resize directions" {
    const source =
        \\local telar = require("telar")
        \\return { api_version = 2, client = { keybindings = {
        \\  telar.bind({ "r" }, telar.action.resize_pane({ direction = "diagonal" })),
        \\} } }
    ;
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 1 }),
    );
    try std.testing.expectEqualStrings(
        "resize-pane direction must be left, right, up, or down",
        diagnostic.message(),
    );
}

test "client config rejects unknown fields without replacing a generation" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { typo = true } }", .source_name = "@config.lua", .number = 1 }),
    );
    try std.testing.expectEqualStrings("unknown field config.client.typo", diagnostic.message());
}

test "Lua callback receives an immutable snapshot and returns bounded effects" {
    const source =
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind({ "s" }, function(ctx)
        \\      if ctx.tab_count ~= 3 or ctx.active_tab_index ~= 2 then error("bad context") end
        \\      return { telar.action.toggle_sidebar(), telar.action.focus_pane({ direction = "left" }) }
        \\    end),
        \\  } },
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 11 });
    defer generation.deinit();
    const batch = try generation.invokeCallback(
        .{ .reference = generation.snapshot.bindings[0].action.lua_callback, .context = .{
            .sidebar_visible = true,
            .tab_count = 3,
            .active_tab_index = 1,
            .pane_count = 2,
            .focused_pane_id = 42,
        } },
        &diagnostic,
    );
    try std.testing.expectEqual(@as(u8, 2), batch.len);
    try std.testing.expectEqualDeep(ActionType.toggle_sidebar, batch.items[0]);
    try std.testing.expectEqualDeep(
        ActionType{ .focus_pane = .left },
        batch.items[1],
    );
}

test "Lua callbacks produce bounded clickable notifications" {
    const source =
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind({ "n" }, function(ctx)
        \\      return telar.action.notification({
        \\        title = "Agent waiting",
        \\        body = "Review its question",
        \\        level = "warning",
        \\        duration_ms = 3000,
        \\        pane_id = ctx.focused_pane_id,
        \\      })
        \\    end),
        \\  } },
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 12 });
    defer generation.deinit();
    const batch = try generation.invokeCallback(
        .{ .reference = generation.snapshot.bindings[0].action.lua_callback, .context = .{
            .sidebar_visible = true,
            .tab_count = 1,
            .active_tab_index = 0,
            .pane_count = 1,
            .focused_pane_id = 42,
        } },
        &diagnostic,
    );
    const notification = &batch.items[0].notification;
    try std.testing.expectEqual(@as(u8, 1), batch.len);
    try std.testing.expectEqual(NotificationLevelType.warning, notification.level);
    try std.testing.expectEqual(@as(u32, 3000), notification.duration_ms);
    try std.testing.expectEqualStrings("Agent waiting", notification.title());
    try std.testing.expectEqualStrings("Review its question", notification.message());
    try std.testing.expectEqual(
        @as(PaneIdType, @enumFromInt(42)),
        notification.target.pane,
    );
}

test "Lua expression returns semantic input instead of terminal bytes" {
    const source =
        \\local telar = require("telar")
        \\return {
        \\  api_version = 2,
        \\  client = { keybindings = {
        \\    telar.bind_expr({ "h" }, function(ctx)
        \\      return telar.input.keys({ "left", "enter" })
        \\    end),
        \\  } },
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 3 });
    defer generation.deinit();
    const decision = try generation.invokeExpression(
        .{ .reference = generation.snapshot.bindings[0].action.lua_expr, .context = .{
            .sidebar_visible = true,
            .tab_count = 1,
            .active_tab_index = 0,
            .pane_count = 1,
            .focused_pane_id = 1,
        } },
        &diagnostic,
    );
    try std.testing.expect(decision == .keys);
    try std.testing.expectEqual(@as(u8, 2), decision.keys.len);
    try std.testing.expectEqual(KeyType.Code.left, decision.keys.items[0].code);
    try std.testing.expectEqual(KeyType.Code.enter, decision.keys.items[1].code);
}

test "Lua callback cannot mutate its context" {
    const source =
        \\local telar = require("telar")
        \\return { api_version = 2, client = { keybindings = {
        \\  telar.bind({ "m" }, function(ctx)
        \\    ctx.tab_count = 99
        \\    return telar.action.toggle_sidebar()
        \\  end),
        \\} } }
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 4 });
    defer generation.deinit();
    try std.testing.expectError(
        error.LuaCallbackFailed,
        generation.invokeCallback(
            .{ .reference = generation.snapshot.bindings[0].action.lua_callback, .context = .{
                .sidebar_visible = true,
                .tab_count = 1,
                .active_tab_index = 0,
                .pane_count = 1,
                .focused_pane_id = 1,
            } },
            &diagnostic,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), "immutable") != null);
}

test "Lua callback execution is interrupted by its instruction budget" {
    const source =
        \\local telar = require("telar")
        \\return { api_version = 2, client = { keybindings = {
        \\  telar.bind({ "l" }, function(ctx) while true do end end),
        \\} } }
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();
    try std.testing.expectError(
        error.LuaCallbackFailed,
        generation.invokeCallback(
            .{ .reference = generation.snapshot.bindings[0].action.lua_callback, .context = .{
                .sidebar_visible = true,
                .tab_count = 1,
                .active_tab_index = 0,
                .pane_count = 1,
                .focused_pane_id = 1,
            } },
            &diagnostic,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), "budget exceeded") != null);
}

test "configuration environment excludes ambient authority" {
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { sidebar = { visible = io == nil and os == nil and debug == nil } } }", .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();
    try std.testing.expect(generation.snapshot.sidebar_visible);
}

test "client bars compile styled static dynamic and command sources" {
    const source =
        \\local telar = require("telar")
        \\return telar.config({
        \\  api_version = 2,
        \\  client = { bars = {
        \\    bottom = {
        \\      left = telar.bar.static({
        \\        { icon = "cpu", text = " CPU", fg = "teal", bg = "#010203", bold = true },
        \\        { text = " 42%", fg = 7, italic = true },
        \\      }),
        \\      center = telar.bar.tabs(),
        \\      right = telar.bar.command({
        \\        command = { "quota", "--json" },
        \\        every_ms = 60000,
        \\        timeout_ms = 450,
        \\        render = function(ctx)
        \\          return {
        \\            { text = ctx.output, fg = "accent" },
        \\            { text = " " .. ctx.active_tab_index, underline = ctx.metrics.available },
        \\          }
        \\        end,
        \\      }),
        \\    },
        \\    top = {
        \\      right = telar.bar.dynamic({
        \\        every_ms = 1000,
        \\        render = function(ctx)
        \\          return {
        \\            {
        \\              icon = "battery-full",
        \\              text = string.format(" %04d-%02d-%02d %02d:%02d:%02d %d%%", ctx.time.year, ctx.time.month, ctx.time.day, ctx.time.hour, ctx.time.minute, ctx.time.second, ctx.metrics.battery_percent),
        \\              fg = "text",
        \\              faint = not ctx.metrics.available,
        \\            },
        \\          }
        \\        end,
        \\      }),
        \\    },
        \\  } },
        \\})
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 8 });
    defer generation.deinit();

    const left = &generation.snapshot.bars.bottom[0].static;
    try std.testing.expectEqual(@as(u8, 2), left.segment_count);
    try std.testing.expectEqual(IconType.cpu, left.slice()[0].icon.?);
    try std.testing.expectEqualStrings(" CPU", left.text(left.slice()[0]));
    try std.testing.expectEqualDeep(ClientColor{ .palette = .teal }, left.slice()[0].style.foreground.?);
    try std.testing.expectEqualDeep(ClientColor{ .value = .{ .rgb = .{ 1, 2, 3 } } }, left.slice()[0].style.background.?);
    try std.testing.expect(left.slice()[0].style.bold);
    try std.testing.expectEqualDeep(ClientColor{ .value = .{ .indexed = 7 } }, left.slice()[1].style.foreground.?);
    try std.testing.expect(left.slice()[1].style.italic);
    try std.testing.expect(generation.snapshot.bars.bottom[1] == .tabs);

    const command = &generation.snapshot.bars.bottom[2].command;
    try std.testing.expectEqual(@as(u64, 60 * std.time.ns_per_s), command.interval_ns);
    try std.testing.expectEqual(@as(u32, 450), command.timeout_ms);
    try std.testing.expectEqualStrings("quota", command.argument(0).?);
    try std.testing.expectEqualStrings("--json", command.argument(1).?);
    try std.testing.expectEqual(@as(u64, 8), command.render.?.generation);

    const context: BarCallbackContext = .{
        .client = .{
            .sidebar_visible = true,
            .tab_count = 4,
            .active_tab_index = 2,
            .pane_count = 3,
            .focused_pane_id = 19,
        },
        .time = .{
            .unix_seconds = 1_788_278_709,
            .year = 2026,
            .month = 9,
            .day = 1,
            .hour = 13,
            .minute = 5,
            .second = 9,
            .weekday = 2,
        },
        .metrics = .{
            .cpu_percent = 38,
            .memory_used_decigib = 123,
            .battery_percent = 61,
        },
    };
    const top = generation.snapshot.bars.top_right.dynamic;
    const clock = try generation.invokeBar(.{ .reference = top.callback, .context = context }, &diagnostic);
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), top.interval_ns);
    try std.testing.expectEqual(@as(u8, 1), clock.segment_count);
    try std.testing.expectEqual(IconType.battery_full, clock.slice()[0].icon.?);
    try std.testing.expectEqualStrings(" 2026-09-01 13:05:09 61%", clock.text(clock.slice()[0]));
    try std.testing.expect(!clock.slice()[0].style.faint);

    var command_context = context;
    command_context.command_output = "74%";
    const quota = try generation.invokeBar(.{
        .reference = command.render.?,
        .context = command_context,
    }, &diagnostic);
    try std.testing.expectEqual(@as(u8, 2), quota.segment_count);
    try std.testing.expectEqualStrings("74%", quota.text(quota.slice()[0]));
    try std.testing.expectEqualStrings(" 3", quota.text(quota.slice()[1]));
    try std.testing.expect(quota.slice()[1].style.underline);
}

test "bar callback context tables are immutable" {
    const source =
        \\local telar = require("telar")
        \\return { api_version = 2, client = { bars = {
        \\  bottom = {
        \\    left = telar.bar.dynamic({ render = function(ctx)
        \\      ctx.time.hour = 0
        \\      return "unreachable"
        \\    end }),
        \\    right = telar.bar.tabs(),
        \\  },
        \\} } }
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 9 });
    defer generation.deinit();
    const callback = generation.snapshot.bars.bottom[0].dynamic.callback;

    try std.testing.expectError(error.LuaBarCallbackFailed, generation.invokeBar(.{
        .reference = callback,
        .context = .{
            .client = .{ .sidebar_visible = true, .tab_count = 1, .active_tab_index = 0, .pane_count = 1, .focused_pane_id = 1 },
            .time = .{ .unix_seconds = 1, .year = 2026, .month = 9, .day = 1, .hour = 12, .minute = 0, .second = 0, .weekday = 2 },
            .metrics = null,
        },
    }, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), "immutable") != null);
}

test "client bars reject invalid positions timing and tab ownership" {
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "local t = require('telar'); return { api_version = 2, client = { bars = { bottom = { left = t.bar.metrics() } } } }",
            .message = "exactly one telar.bar.tabs()",
        },
        .{
            .source = "local t = require('telar'); return { api_version = 2, client = { bars = { bottom = { left = t.bar.tabs(), right = t.bar.tabs() } } } }",
            .message = "exactly one telar.bar.tabs()",
        },
        .{
            .source = "local t = require('telar'); return { api_version = 2, client = { bars = { top = { left = t.bar.static('x') } } } }",
            .message = "unknown field config.client.bars.top.left",
        },
        .{
            .source = "local t = require('telar'); return { api_version = 2, client = { bars = { top = { right = t.bar.tabs() } } } }",
            .message = "top.right cannot contain tabs",
        },
        .{
            .source = "local t = require('telar'); return { api_version = 2, client = { bars = { bottom = { left = t.bar.dynamic({ every_ms = 99, render = function() end }), right = t.bar.tabs() } } } }",
            .message = "every_ms must be in 100..3600000",
        },
        .{
            .source = "local t = require('telar'); return { api_version = 2, client = { bars = { bottom = { left = t.bar.command({ command = {}, timeout_ms = 99 }), right = t.bar.tabs() } } } }",
            .message = "timeout_ms must be in 100..10000",
        },
    };

    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = case.source, .source_name = "@config.lua", .number = 1 }));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), case.message) != null);
    }
}

test "runtime proxy defaults to the Claude Code and Codex API hosts" {
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2 }", .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();

    var storage: [max_intercept_hosts][]const u8 = undefined;
    const hosts = generation.snapshot.runtime.proxyInterceptHosts(&storage);

    try std.testing.expectEqual(@as(usize, 3), hosts.len);
    try std.testing.expectEqualStrings("api.anthropic.com", hosts[0]);
    try std.testing.expectEqualStrings("api.openai.com", hosts[1]);
    try std.testing.expectEqualStrings("chatgpt.com", hosts[2]);
}

test "an explicit empty intercept host list disables interception" {
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, runtime = { proxy = { intercept_hosts = {} } } }", .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();

    var storage: [max_intercept_hosts][]const u8 = undefined;
    const hosts = generation.snapshot.runtime.proxyInterceptHosts(&storage);

    try std.testing.expectEqual(@as(usize, 0), hosts.len);
}

test "runtime config compiles bounded graphics, proxy, and description values" {
    var diagnostic: Diagnostic = .{};
    const source =
        \\return {
        \\  api_version = 2,
        \\  runtime = {
        \\    history = { path = "state/history.db" },
        \\    graphics = { pane_mib = 32, global_mib = 128 },
        \\    proxy = {
        \\      enabled = true,
        \\      ca_dir = "state/proxy",
        \\      capture = {
        \\        enabled = true,
        \\        max_part_bytes = 1024,
        \\        max_exchange_bytes = 2048,
        \\        max_total_bytes = 8192,
        \\        join_timeout_ms = 1500,
        \\      },
        \\      intercept_hosts = { "updates.example.com", "API.EXAMPLE.COM" },
        \\    },
        \\    agent_descriptions = {
        \\      command = { "claude", "--print", "--tools", "" },
        \\      timeout_ms = 12000,
        \\    },
        \\  },
        \\}
    ;
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();
    try std.testing.expectEqual(
        @as(usize, 32 * 1024 * 1024),
        generation.snapshot.runtime.graphics_pane_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 128 * 1024 * 1024),
        generation.snapshot.runtime.graphics_global_bytes,
    );
    try std.testing.expectEqualStrings(
        "state/history.db",
        generation.snapshot.runtime.historyPath().?,
    );
    try std.testing.expect(generation.snapshot.runtime.proxy_enabled);
    try std.testing.expectEqualStrings(
        "state/proxy",
        generation.snapshot.runtime.proxyCaDir().?,
    );
    try std.testing.expect(generation.snapshot.runtime.proxy_capture_enabled);
    try std.testing.expectEqual(@as(usize, 1024), generation.snapshot.runtime.proxy_capture_max_part_bytes);
    try std.testing.expectEqual(@as(usize, 2048), generation.snapshot.runtime.proxy_capture_max_exchange_bytes);
    try std.testing.expectEqual(@as(usize, 8192), generation.snapshot.runtime.proxy_capture_max_total_bytes);
    try std.testing.expectEqual(@as(u32, 1500), generation.snapshot.runtime.proxy_capture_join_timeout_ms);
    var intercept_host_storage: [max_intercept_hosts][]const u8 = undefined;
    const intercept_hosts = generation.snapshot.runtime.proxyInterceptHosts(&intercept_host_storage);
    try std.testing.expectEqual(@as(usize, 2), intercept_hosts.len);
    try std.testing.expectEqualStrings("api.example.com", intercept_hosts[0]);
    try std.testing.expectEqualStrings("updates.example.com", intercept_hosts[1]);
    var arguments: [config_model.max_agent_description_command_args][]const u8 = undefined;
    const description_command = &generation.snapshot.runtime.agent_descriptions;
    try std.testing.expect(description_command.enabled());
    try std.testing.expectEqual(@as(u32, 12_000), description_command.timeout_ms);
    const argv = description_command.arguments(&arguments);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("claude", argv[0]);
    try std.testing.expectEqualStrings("", argv[3]);
    try std.testing.expect(!generation.snapshot.runtime.engine.enabled());
}

test "runtime engine parses its command, deadline and idle interval" {
    var diagnostic: Diagnostic = .{};
    const source =
        \\return {
        \\  api_version = 2,
        \\  runtime = {
        \\    engine = {
        \\      command = { "pi", "--mode", "rpc", "--no-session", "--no-tools" },
        \\      timeout_ms = 20000,
        \\      idle_timeout_ms = 120000,
        \\    },
        \\  },
        \\}
    ;
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();

    const engine = &generation.snapshot.runtime.engine;
    try std.testing.expect(engine.enabled());
    try std.testing.expectEqual(@as(u32, 20_000), engine.timeout_ms);
    try std.testing.expectEqual(@as(u32, 120_000), generation.snapshot.runtime.engine_idle_timeout_ms);
    var arguments: [config_model.max_agent_description_command_args][]const u8 = undefined;
    const argv = engine.arguments(&arguments);
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("--no-tools", argv[4]);
    try std.testing.expect(!generation.snapshot.runtime.agent_descriptions.enabled());

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "return { api_version = 2, runtime = { engine = { command = { 'pi' }, idle_timeout_ms = 5 } } }",
            .message = "config.runtime.engine.idle_timeout_ms must be in 10000..3600000",
        },
        .{
            .source = "return { api_version = 2, runtime = { engine = { command = {} } } }",
            .message = "config.runtime.engine.command must contain 1..32 arguments",
        },
        .{
            .source = "return { api_version = 2, runtime = { engine = { command = { 'pi' }, model = 'x' } } }",
            .message = "config.runtime.engine",
        },
    };
    for (cases) |case| {
        var case_diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &case_diagnostic }, .{ .source = case.source, .source_name = "@config.lua", .number = 1 }));
        try std.testing.expect(std.mem.indexOf(u8, case_diagnostic.message(), case.message) != null);
    }
}

test "runtime proxy accepts wildcard intercept hosts" {
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, runtime = { proxy = { intercept_hosts = { '*.Example.com', '*' } } } }", .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();

    var storage: [max_intercept_hosts][]const u8 = undefined;
    const hosts = generation.snapshot.runtime.proxyInterceptHosts(&storage);
    try std.testing.expectEqual(@as(usize, 2), hosts.len);
    try std.testing.expectEqualStrings("*", hosts[0]);
    try std.testing.expectEqualStrings("*.example.com", hosts[1]);
}

test "runtime proxy rejects unsafe intercept host patterns" {
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "return { api_version = 2, runtime = { proxy = { intercept_hosts = { '*example.com' } } } }",
            .message = "is not a valid hostname",
        },
        .{
            .source = "return { api_version = 2, runtime = { proxy = { intercept_hosts = { 'api.*.example.com' } } } }",
            .message = "is not a valid hostname",
        },
        .{
            .source = "local h = {}; for i = 1, 257 do h[i] = 'host' .. i .. '.example' end; return { api_version = 2, runtime = { proxy = { intercept_hosts = h } } }",
            .message = "exceeds 256 entries",
        },
        .{
            .source = "return { api_version = 2, runtime = { proxy = { capture = { max_part_bytes = 9, max_exchange_bytes = 8 } } } }",
            .message = "byte limits must satisfy part <= exchange <= total",
        },
    };
    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(
            error.InvalidConfig,
            Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = case.source, .source_name = "@config.lua", .number = 1 }),
        );
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), case.message) != null);
    }
}

test "runtime proxy accepts and sorts 256 intercept hosts" {
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "local h = {}; for i = 256, 1, -1 do h[#h + 1] = 'host' .. i .. '.example' end; return { api_version = 2, runtime = { proxy = { intercept_hosts = h } } }", .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();
    var storage: [max_intercept_hosts][]const u8 = undefined;
    const hosts = generation.snapshot.runtime.proxyInterceptHosts(&storage);
    try std.testing.expectEqual(@as(usize, 256), hosts.len);
    for (hosts[1..], hosts[0 .. hosts.len - 1]) |current, previous|
        try std.testing.expect(orderHostname_module(previous, current) == .lt);
}

test "runtime description command rejects unbounded values" {
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "local c = {}; for i = 1, 33 do c[i] = 'x' end; return { api_version = 2, runtime = { agent_descriptions = { command = c } } }",
            .message = "must contain 1..32 arguments",
        },
        .{
            .source = "return { api_version = 2, runtime = { agent_descriptions = { command = { 'codex', string.rep('x', 4096) } } } }",
            .message = "exceeds its 4096-byte limit",
        },
        .{
            .source = "return { api_version = 2, runtime = { agent_descriptions = { command = { 'codex' }, timeout_ms = 999 } } }",
            .message = "timeout_ms must be in 1000..60000",
        },
        .{
            .source = "return { api_version = 2, runtime = { agent_descriptions = { command = { 'codex', extra = true } } } }",
            .message = "command must be an array",
        },
    };
    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = case.source, .source_name = "@config.lua", .number = 1 }));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), case.message) != null);
    }
}

test "runtime ProxyTLS config rejects live Lua middleware closures" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, runtime = { proxy = { enabled = true, middleware = function() end } } }", .source_name = "@config.lua", .number = 1 }),
    );
    try std.testing.expectEqualStrings(
        "unknown field config.runtime.proxy.middleware",
        diagnostic.message(),
    );
}

test "profile overlays base config before CLI locks are applied" {
    const source =
        \\return {
        \\  api_version = 2,
        \\  client = {
        \\    prefix = "ctrl+b",
        \\    sidebar = { visible = true, renderer = "automatic" },
        \\    keybindings = {
        \\      require("telar").bind_expr({ "f" }, function(ctx)
        \\        return require("telar").input.forward()
        \\      end),
        \\    },
        \\  },
        \\  runtime = { graphics = { pane_mib = 64, global_mib = 256 } },
        \\  profiles = {
        \\    remote = {
        \\      client = {
        \\        prefix = "ctrl+s",
        \\        sidebar = { visible = false, renderer = "cells" },
        \\      },
        \\      runtime = { graphics = { pane_mib = 16, global_mib = 64 } },
        \\    },
        \\  },
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadSource(.{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .diagnostic = &diagnostic,
    }, .{
        .source = source,
        .source_name = "@config.lua",
        .number = 1,
        .profile = "remote",
    });
    defer generation.deinit();
    try std.testing.expect(!generation.snapshot.sidebar_visible);
    try std.testing.expectEqual(SidebarRenderingType.cells, generation.snapshot.sidebar_rendering);
    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), generation.snapshot.runtime.graphics_pane_bytes);
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), generation.snapshot.runtime.graphics_global_bytes);
    const binding = generation.snapshot.bindings[0];
    try std.testing.expectEqualDeep(try parseKey_module("ctrl+s"), binding.keys[0]);
    try std.testing.expectEqualDeep(try parseKey_module("f"), binding.keys[1]);
    const decision = try generation.invokeExpression(
        .{ .reference = binding.action.lua_expr, .context = .{
            .sidebar_visible = false,
            .tab_count = 1,
            .active_tab_index = 0,
            .pane_count = 1,
            .focused_pane_id = 1,
        } },
        &diagnostic,
    );
    try std.testing.expect(decision == .forward_binding);
    try std.testing.expectEqual(@as(u8, 2), decision.forward_binding.len);
    try std.testing.expectEqualDeep(try parseKey_module("ctrl+s"), decision.forward_binding.items[0]);
    try std.testing.expectEqualDeep(try parseKey_module("f"), decision.forward_binding.items[1]);
}

test "selected profile must exist" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.UnknownProfile,
        Generation.loadSource(.{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .diagnostic = &diagnostic,
        }, .{
            .source = "return { api_version = 2, profiles = {} }",
            .source_name = "@config.lua",
            .number = 1,
            .profile = "missing",
        }),
    );
    try std.testing.expectEqualStrings("profile 'missing' is not defined", diagnostic.message());
}

test "unselected profiles are still validated deeply" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.InvalidConfig,
        Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, profiles = { broken = { client = { typo = true } } } }", .source_name = "@config.lua", .number = 1 }),
    );
    try std.testing.expectEqualStrings("unknown field config.client.typo", diagnostic.message());
}

test "local modules are contained and participate in reload fingerprints" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    {
        var module = try temp.dir.createFile(io, "settings.lua", .{});
        defer module.close(io);
        try module.writeStreamingAll(io, "return { renderer = 'cells' }");
    }
    {
        var config = try temp.dir.createFile(io, "config.lua", .{});
        defer config.close(io);
        try config.writeStreamingAll(
            io,
            "local s = require('settings'); return { api_version = 2, client = { sidebar = s } }",
        );
    }
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var config_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try std.fmt.bufPrint(
        &config_path_buffer,
        "{s}/config.lua",
        .{directory_buffer[0..directory_len]},
    );
    var diagnostic: Diagnostic = .{};
    const generation = try Generation.loadFile(.{
        .gpa = std.testing.allocator,
        .io = io,
        .diagnostic = &diagnostic,
    }, .{ .path = config_path, .number = 1 });
    defer generation.deinit();
    try std.testing.expectEqual(@as(u8, 1), generation.modules.dependency_count);
    try std.testing.expectEqual(SidebarRenderingType.cells, generation.snapshot.sidebar_rendering);
    const before = generation.watchFingerprint(io, config_path);
    {
        var module = try temp.dir.createFile(io, "settings.lua", .{ .truncate = true });
        defer module.close(io);
        try module.writeStreamingAll(io, "return { renderer = 'automatic', visible = false }");
    }
    try std.testing.expect(before != generation.watchFingerprint(io, config_path));
}

test "local require rejects a symlink escaping the config directory" {
    const io = std.testing.io;
    var config_temp = std.testing.tmpDir(.{});
    defer config_temp.cleanup();
    var outside_temp = std.testing.tmpDir(.{});
    defer outside_temp.cleanup();
    {
        var outside = try outside_temp.dir.createFile(io, "outside.lua", .{});
        defer outside.close(io);
        try outside.writeStreamingAll(io, "return {}");
    }
    var outside_directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const outside_directory_len = try outside_temp.dir.realPath(io, &outside_directory_buffer);
    var outside_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const outside_path = try std.fmt.bufPrint(
        &outside_path_buffer,
        "{s}/outside.lua",
        .{outside_directory_buffer[0..outside_directory_len]},
    );
    try config_temp.dir.symLink(io, outside_path, "escape.lua", .{});
    {
        var config = try config_temp.dir.createFile(io, "config.lua", .{});
        defer config.close(io);
        try config.writeStreamingAll(
            io,
            "require('escape'); return { api_version = 2 }",
        );
    }
    var config_directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const config_directory_len = try config_temp.dir.realPath(io, &config_directory_buffer);
    var config_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try std.fmt.bufPrint(
        &config_path_buffer,
        "{s}/config.lua",
        .{config_directory_buffer[0..config_directory_len]},
    );
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(
        error.LuaRuntimeFailed,
        Generation.loadFile(.{
            .gpa = std.testing.allocator,
            .io = io,
            .diagnostic = &diagnostic,
        }, .{ .path = config_path, .number = 1 }),
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message(), "escapes") != null);
}

test {
    // Only referenced through non-pub imports above, so its tests never run
    // unless the container is referenced here.
    _ = default_bindings;
}

test "runtime agents extend built-ins and add custom manifests" {
    const source =
        \\return {
        \\  api_version = 2,
        \\  runtime = {
        \\    agents = {
        \\      { name = "gemini", process_names = { "gemini" }, process_paths = { "/@google/gemini-cli/" },
        \\        brand = { "gemini" }, identity = { "gemini cli" }, working = { "esc to cancel" },
        \\        command_tools = { { tool = "run_shell_command", field = "command" } } },
        \\      { name = "claude", working = { "brewing" } },
        \\    },
        \\  },
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();
    const table = &generation.snapshot.runtime.agent_manifests;

    try std.testing.expectEqual(@as(u8, 4), table.count);
    const gemini = table.find(@enumFromInt(first_custom_agent_provider_module)).?;
    try std.testing.expectEqualStrings("gemini", gemini.nameSlice());
    try std.testing.expectEqual(gemini.provider, table.providerFromExecutable("gemini").?);
    try std.testing.expectEqual(gemini.provider, table.detect("Gemini CLI  esc to cancel").?.provider);
    try std.testing.expectEqualStrings("command", table.commandField(gemini.provider, "run_shell_command").?);
    try std.testing.expectEqual(StatusType.working, table.detect("brewing").?.status);
    try std.testing.expectEqual(AgentProviderType.claude, table.detect("Claude Code").?.provider);
}

test "runtime agents reject bad names and oversized phrases" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, runtime = { agents = { { name = \"Gemini\" } } } }", .source_name = "@config.lua", .number = 1 }));
    try std.testing.expect(std.mem.startsWith(u8, diagnostic.message(), "config.runtime.agents[1].name must be"));

    var long_phrase: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &long_phrase }, .{ .source = "return { api_version = 2, runtime = { agents = { { name = \"x\", working = { string.rep(\"a\", 49) } } } } }", .source_name = "@config.lua", .number = 1 }));
    try std.testing.expectEqualStrings("config.runtime.agents[1].working[1] is too long", long_phrase.message());
}

test "runtime agents carry presentation and the attachment scheme" {
    const source =
        \\return {
        \\  api_version = 2,
        \\  runtime = {
        \\    agents = {
        \\      { name = "gemini", display_name = "Gemini CLI", placeholder = "Fresh Gemini chat",
        \\        icon = "G", attachments = "ordered" },
        \\      { name = "claude", display_name = "Claude" },
        \\    },
        \\  },
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = source, .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();
    const table = &generation.snapshot.runtime.agent_manifests;
    const gemini: AgentProviderType = @enumFromInt(first_custom_agent_provider_module);
    var buffer: [max_agent_session_title_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("Gemini CLI", table.displayName(gemini));
    try std.testing.expectEqualStrings("Fresh Gemini chat", table.placeholderTitle(gemini, &buffer));
    try std.testing.expectEqualStrings("G", table.icon(gemini));
    try std.testing.expectEqual(AgentAttachmentMarkers.ordered, table.attachments(gemini));
    try std.testing.expectEqualStrings("Claude", table.displayName(.claude));
    try std.testing.expectEqualStrings("New Claude session", table.placeholderTitle(.claude, &buffer));
    try std.testing.expectEqual(AgentAttachmentMarkers.stable_number, table.attachments(.claude));
    try std.testing.expectEqual(AgentAttachmentMarkers.pasted_path, table.attachments(.pi));
}

test "runtime agents reject bad presentation fields" {
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{
            .source = "return { api_version = 2, runtime = { agents = { { name = \"x\", icon = \"GG\" } } } }",
            .message = "config.runtime.agents[1].icon must be exactly one cell wide",
        },
        .{
            .source = "return { api_version = 2, runtime = { agents = { { name = \"x\", attachments = \"paths\" } } } }",
            .message = "config.runtime.agents[1].attachments must be \"none\", \"ordered\", \"stable_number\" or \"pasted_path\"",
        },
        .{
            .source = "return { api_version = 2, runtime = { agents = { { name = \"x\", display_name = string.rep(\"a\", 33) } } } }",
            .message = "config.runtime.agents[1].display_name is too long",
        },
        .{
            .source = "return { api_version = 2, runtime = { agents = { { name = \"x\", placeholder = \"a\\tb\" } } } }",
            .message = "config.runtime.agents[1].placeholder must be a printable string",
        },
        .{
            .source = "return { api_version = 2, runtime = { agents = { { name = \"x\", icon = 7 } } } }",
            .message = "config.runtime.agents[1].icon must be a printable string",
        },
    };
    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = case.source, .source_name = "@config.lua", .number = 1 }));
        try std.testing.expectEqualStrings(case.message, diagnostic.message());
    }
}

test "notification delivery parses and rejects unknown channels" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { notifications = { delivery = \"system\" } } }", .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();
    try std.testing.expectEqual(Delivery.system, generation.snapshot.notification_delivery);

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &invalid }, .{ .source = "return { api_version = 2, client = { notifications = { delivery = \"popup\" } } }", .source_name = "@config.lua", .number = 1 }));
    try std.testing.expectEqualStrings("config.client.notifications.delivery must be telar, terminal or system", invalid.message());
}

test "appearance themes parse and reject unknown names" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { appearance = { light = \"catppuccin\", dark = \"vesper\" } } }", .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();
    try std.testing.expectEqual(theme_mod.Builtin.catppuccin, generation.snapshot.theme_light.?.base);
    try std.testing.expectEqual(theme_mod.Builtin.vesper, generation.snapshot.theme_dark.?.base);

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &invalid }, .{ .source = "return { api_version = 2, client = { appearance = { light = \"neon\" } } }", .source_name = "@config.lua", .number = 1 }));
}

test "command-tab actions parse a bounded argv and reject empty commands" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { keybindings = { telar.bind({ \"ctrl+g\" }, telar.action.command_tab({ command = { \"lazygit\", \"-p\" }, label = \"git\" })) } } }", .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();

    const parsed = generation.snapshot.bindings[0].action.command_tab;
    try std.testing.expectEqualStrings("lazygit", parsed.argument(0));
    try std.testing.expectEqualStrings("-p", parsed.argument(1));
    try std.testing.expectEqualStrings("git", parsed.label());

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &invalid }, .{ .source = "return { api_version = 2, client = { keybindings = { telar.bind({ \"ctrl+g\" }, telar.action.command_tab({ command = {} })) } } }", .source_name = "@config.lua", .number = 1 }));
}

test "runtime history filters parse and reject invalid patterns" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, runtime = { history = { secrets_filter = false, command_filters = { \"vault kv\" }, cwd_filters = { \"/private\" } } } }", .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();

    const filters = generation.snapshot.runtime.history_filters;
    try std.testing.expect(!filters.secrets);
    try std.testing.expectEqualStrings("vault kv", filters.commands.at(0));
    try std.testing.expectEqualStrings("/private", filters.cwds.at(0));
    try std.testing.expectEqual(@as(?[]const u8, null), generation.snapshot.runtime.historyPath());

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &invalid }, .{ .source = "return { api_version = 2, runtime = { history = { command_filters = { \"\" } } } }", .source_name = "@config.lua", .number = 1 }));

    var bad_flag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &bad_flag }, .{ .source = "return { api_version = 2, runtime = { history = { secrets_filter = \"yes\" } } }", .source_name = "@config.lua", .number = 1 }));
}

test "client history config toggles agent command visibility" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { history = { show_agent_commands = true } } }", .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();
    try std.testing.expect(generation.snapshot.history_show_agent_commands);

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &invalid }, .{ .source = "return { api_version = 2, client = { history = { show_agent_commands = \"yes\" } } }", .source_name = "@config.lua", .number = 1 }));
}

test "client history enter mode parses paste or run only" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { history = { enter = \"run\" } } }", .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();
    try std.testing.expect(generation.snapshot.history_enter_runs);

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &invalid }, .{ .source = "return { api_version = 2, client = { history = { enter = \"always\" } } }", .source_name = "@config.lua", .number = 1 }));
}

test "client history match mode parses fuzzy or fts only" {
    var diagnostic: Diagnostic = .{};
    var generation = try Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &diagnostic }, .{ .source = "return { api_version = 2, client = { history = { match = \"fts\" } } }", .source_name = "@config.lua", .number = 1 });
    defer generation.deinit();
    try std.testing.expect(generation.snapshot.history_match_fts);

    var invalid: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, Generation.loadSource(.{ .gpa = std.testing.allocator, .io = std.testing.io, .diagnostic = &invalid }, .{ .source = "return { api_version = 2, client = { history = { match = \"regex\" } } }", .source_name = "@config.lua", .number = 1 }));
}
