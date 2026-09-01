//! Application policy for routing one configured semantic action.

const std = @import("std");
const lua_config = @import("../../../config/root.zig");
const input = @import("../../../input/root.zig");
const lua_action = @import("lua_action.zig");

const Action = input.action.Action;
const PluginAction = input.action.PluginAction;
const keybind = input.keybind;

pub const Authority = union(enum) {
    suppressed,
    available: struct {
        copy_mode_active: bool,
    },
};

pub const Control = enum {
    continue_routing,
    stop,
};

pub const Effects = struct {
    context: *anyopaque,
    native: *const fn (*anyopaque, Action) anyerror!Control,
    lua: *const fn (*anyopaque, lua_action.Command) anyerror!lua_action.Outcome,
    plugin: *const fn (*anyopaque, PluginAction) anyerror!void,
    key: *const fn (*anyopaque, keybind.Key) anyerror!void,
    paste: *const fn (*anyopaque, []const u8) anyerror!void,
};

pub const ActionRoutingHandler = struct {
    effects: Effects,

    /// Routes one configured action without exposing source-specific policy to
    /// the host input entrypoint.
    ///
    /// ```zig
    /// const control = try handler.execute(action, authority);
    /// ```
    pub fn execute(handler: *ActionRoutingHandler, value: Action, authority: Authority) !Control {
        const available = switch (authority) {
            .suppressed => return .continue_routing,
            .available => |state| state,
        };

        return switch (value) {
            .lua_callback => |reference| handler.executeLua(
                .{ .callback = reference },
                available.copy_mode_active,
            ),
            .lua_expr => |reference| handler.executeLua(
                .{ .expression = reference },
                available.copy_mode_active,
            ),
            .plugin => |requested| plugin: {
                try handler.effects.plugin(handler.effects.context, requested);

                break :plugin .continue_routing;
            },
            else => handler.effects.native(handler.effects.context, value),
        };
    }

    fn executeLua(handler: *ActionRoutingHandler, command: lua_action.Command, copy_mode_active: bool) !Control {
        const outcome = try handler.effects.lua(handler.effects.context, command);

        switch (outcome) {
            .applied, .unavailable, .invocation_failed, .validation_failed => return .continue_routing,
            .exit => return .stop,
            .input => |decision| switch (decision) {
                .consume => {},
                .forward_binding, .keys => |keys| for (keys.slice()) |key_value| {
                    try handler.effects.key(handler.effects.context, key_value);
                },
                .paste => |paste| {
                    if (!copy_mode_active) {
                        try handler.effects.paste(handler.effects.context, paste.slice());
                    }
                },
            },
        }

        return .continue_routing;
    }
};

const Event = enum {
    native,
    lua,
    plugin,
    key,
    paste,
};

const Failure = enum {
    none,
    native,
    lua,
    plugin,
    key,
    paste,
};

const Capture = struct {
    events: [lua_config.max_expression_keys + 1]Event = undefined,
    event_count: usize = 0,
    native_control: Control = .continue_routing,
    lua_outcome: lua_action.Outcome = .applied,
    lua_command: ?lua_action.Command = null,
    plugin_action: PluginAction = undefined,
    keys: [lua_config.max_expression_keys]keybind.Key = undefined,
    key_count: usize = 0,
    paste_bytes: [32]u8 = undefined,
    paste_len: usize = 0,
    failure: Failure = .none,

    fn port(capture: *Capture) Effects {
        return .{
            .context = capture,
            .native = native,
            .lua = lua,
            .plugin = plugin,
            .key = key,
            .paste = paste,
        };
    }

    fn record(capture: *Capture, event: Event) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn native(raw_context: *anyopaque, value: Action) !Control {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        _ = value;
        capture.record(.native);

        if (capture.failure == .native) {
            return error.NativeActionFailed;
        }

        return capture.native_control;
    }

    fn lua(raw_context: *anyopaque, command: lua_action.Command) !lua_action.Outcome {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.lua);
        capture.lua_command = command;

        if (capture.failure == .lua) {
            return error.LuaActionFailed;
        }

        return capture.lua_outcome;
    }

    fn plugin(raw_context: *anyopaque, requested: PluginAction) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.plugin);
        capture.plugin_action = requested;

        if (capture.failure == .plugin) {
            return error.PluginActionFailed;
        }
    }

    fn key(raw_context: *anyopaque, value: keybind.Key) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.key);
        capture.keys[capture.key_count] = value;
        capture.key_count += 1;

        if (capture.failure == .key) {
            return error.KeyRoutingFailed;
        }
    }

    fn paste(raw_context: *anyopaque, text: []const u8) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.record(.paste);
        std.debug.assert(text.len <= capture.paste_bytes.len);
        @memcpy(capture.paste_bytes[0..text.len], text);
        capture.paste_len = text.len;

        if (capture.failure == .paste) {
            return error.PasteRoutingFailed;
        }
    }
};

fn routingAuthority(copy_mode_active: bool) Authority {
    return .{ .available = .{ .copy_mode_active = copy_mode_active } };
}

test "action routing suppresses every configured source while a prompt owns input" {
    var capture: Capture = .{};
    var handler: ActionRoutingHandler = .{ .effects = capture.port() };

    try std.testing.expectEqual(
        Control.continue_routing,
        try handler.execute(.toggle_sidebar, .suppressed),
    );
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "action routing selects native and plugin effects" {
    var capture: Capture = .{ .native_control = .stop };
    var handler: ActionRoutingHandler = .{ .effects = capture.port() };

    try std.testing.expectEqual(Control.stop, try handler.execute(.detach, routingAuthority(false)));
    try std.testing.expectEqualSlices(Event, &.{.native}, capture.events[0..capture.event_count]);

    capture = .{};
    handler = .{ .effects = capture.port() };
    const requested: PluginAction = .{ .plugin = 7, .action = 11 };
    try std.testing.expectEqual(
        Control.continue_routing,
        try handler.execute(.{ .plugin = requested }, routingAuthority(false)),
    );
    try std.testing.expectEqualSlices(Event, &.{.plugin}, capture.events[0..capture.event_count]);
    try std.testing.expectEqualDeep(requested, capture.plugin_action);
}

test "action routing maps terminal Lua outcomes to router control" {
    var capture: Capture = .{ .lua_outcome = .{ .validation_failed = error.InvalidLuaBatch } };
    var handler: ActionRoutingHandler = .{ .effects = capture.port() };
    const reference: input.action.CallbackRef = .{ .generation = 3, .id = 9 };

    try std.testing.expectEqual(
        Control.continue_routing,
        try handler.execute(.{ .lua_callback = reference }, routingAuthority(false)),
    );
    try std.testing.expectEqualSlices(Event, &.{.lua}, capture.events[0..capture.event_count]);
    try std.testing.expectEqualDeep(lua_action.Command{ .callback = reference }, capture.lua_command.?);

    capture = .{ .lua_outcome = .exit };
    handler = .{ .effects = capture.port() };
    try std.testing.expectEqual(
        Control.stop,
        try handler.execute(.{ .lua_expr = reference }, routingAuthority(false)),
    );
    try std.testing.expectEqualDeep(lua_action.Command{ .expression = reference }, capture.lua_command.?);
}

test "action routing re-enters semantic keys and guards expression paste" {
    var keys: lua_config.InputKeys = .{};
    keys.items[0] = try keybind.parseKey("left");
    keys.items[1] = try keybind.parseKey("enter");
    keys.len = 2;
    var capture: Capture = .{ .lua_outcome = .{ .input = .{ .forward_binding = keys } } };
    var handler: ActionRoutingHandler = .{ .effects = capture.port() };

    _ = try handler.execute(
        .{ .lua_expr = .{ .generation = 1, .id = 2 } },
        routingAuthority(false),
    );

    try std.testing.expectEqualSlices(Event, &.{ .lua, .key, .key }, capture.events[0..capture.event_count]);
    try std.testing.expectEqualSlices(keybind.Key, keys.slice(), capture.keys[0..capture.key_count]);

    var paste: lua_config.InputPaste = .{};
    @memcpy(paste.bytes[0..5], "hello");
    paste.len = 5;
    capture = .{ .lua_outcome = .{ .input = .{ .paste = paste } } };
    handler = .{ .effects = capture.port() };
    _ = try handler.execute(
        .{ .lua_expr = .{ .generation = 1, .id = 2 } },
        routingAuthority(false),
    );
    try std.testing.expectEqualSlices(Event, &.{ .lua, .paste }, capture.events[0..capture.event_count]);
    try std.testing.expectEqualStrings("hello", capture.paste_bytes[0..capture.paste_len]);

    capture = .{ .lua_outcome = .{ .input = .{ .paste = paste } } };
    handler = .{ .effects = capture.port() };
    _ = try handler.execute(
        .{ .lua_expr = .{ .generation = 1, .id = 2 } },
        routingAuthority(true),
    );
    try std.testing.expectEqualSlices(Event, &.{.lua}, capture.events[0..capture.event_count]);

    capture = .{ .lua_outcome = .{ .input = .consume } };
    handler = .{ .effects = capture.port() };
    _ = try handler.execute(
        .{ .lua_expr = .{ .generation = 1, .id = 2 } },
        routingAuthority(false),
    );
    try std.testing.expectEqualSlices(Event, &.{.lua}, capture.events[0..capture.event_count]);
}

test "action routing propagates a selected effect failure before later input" {
    var keys: lua_config.InputKeys = .{};
    keys.items[0] = try keybind.parseKey("left");
    keys.items[1] = try keybind.parseKey("enter");
    keys.len = 2;
    var capture: Capture = .{
        .lua_outcome = .{ .input = .{ .keys = keys } },
        .failure = .key,
    };
    var handler: ActionRoutingHandler = .{ .effects = capture.port() };

    try std.testing.expectError(
        error.KeyRoutingFailed,
        handler.execute(.{ .lua_expr = .{ .generation = 1, .id = 2 } }, routingAuthority(false)),
    );
    try std.testing.expectEqualSlices(Event, &.{ .lua, .key }, capture.events[0..capture.event_count]);
}
