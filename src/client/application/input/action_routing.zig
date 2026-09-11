//! Application policy for routing one configured semantic action.

const action_module = @import("../../input/action.zig");
const PaneIdType = @import("telar-core").PaneId;
const RepeatPolicyType = @import("../../input/RepeatPolicy.zig");
const std = @import("std");
const ActionRoutingCapture = @import("ActionRoutingCapture.zig");
const ActionRoutingHandler = @import("ActionRoutingHandler.zig");
const PluginAction = @import("../../input/PluginAction.zig");
const CallbackRefType = @import("../../input/CallbackRef.zig");
const lua_action = @import("lua_action.zig");
const InputKeysType = @import("../../config/InputKeys.zig");
const chord = @import("../../input/chord.zig");
const KeyType = @import("../../input/Key.zig");
const InputPasteType = @import("../../config/InputPaste.zig");

pub const Authority = union(enum) {
    suppressed,
    available: struct {
        copy_mode_active: bool,
        agent_mode_active: bool = false,
    },
};

pub const Control = enum {
    continue_routing,
    stop,
};

/// Only native wheel-step actions may repeat, at most ten steps per second.
/// For example: `const policy = repeatPolicy(.{ .scroll_pane = .up }, pane_id);`.
pub fn repeatPolicy(value: action_module.Action, pane_id: PaneIdType) ?RepeatPolicyType {
    return switch (value) {
        .scroll_pane => .{ .interval_ns = 100 * std.time.ns_per_ms, .context = @intFromEnum(pane_id) },
        else => null,
    };
}

pub const Event = enum {
    native,
    lua,
    plugin,
    key,
    paste,
};

pub const Failure = enum {
    none,
    native,
    lua,
    plugin,
    key,
    paste,
};

fn routingAuthority(copy_mode_active: bool) Authority {
    return .{ .available = .{ .copy_mode_active = copy_mode_active } };
}

test "repeat policy enables only native scroll with exact pane ownership" {
    const pane_id: PaneIdType = @enumFromInt(7);
    for ([_]action_module.ScrollDirection{ .up, .down }) |direction| {
        const policy = repeatPolicy(.{ .scroll_pane = direction }, pane_id).?;
        try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), policy.interval_ns);
        try std.testing.expectEqual(@as(u64, 7), policy.context);
    }

    const non_repeating = [_]action_module.Action{
        .close_pane,
        .close_tab,
        .detach,
        .toggle_sidebar,
        .enter_copy_mode,
        .{ .focus_pane = .left },
        .{ .lua_callback = .{ .generation = 1, .id = 1 } },
        .{ .lua_expr = .{ .generation = 1, .id = 1 } },
        .{ .plugin = .{ .plugin = 1, .action = 1 } },
    };

    for (non_repeating) |value| {
        try std.testing.expect(repeatPolicy(value, pane_id) == null);
    }
}

test "action routing suppresses every configured source while a prompt owns input" {
    var capture: ActionRoutingCapture = .{};
    var handler: ActionRoutingHandler = .{ .effects = capture.port() };

    try std.testing.expectEqual(
        Control.continue_routing,
        try handler.execute(.toggle_sidebar, .suppressed),
    );
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "action routing selects native and plugin effects" {
    var capture: ActionRoutingCapture = .{ .native_control = .stop };
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
    var capture: ActionRoutingCapture = .{ .lua_outcome = .{ .validation_failed = error.InvalidLuaBatch } };
    var handler: ActionRoutingHandler = .{ .effects = capture.port() };
    const reference: CallbackRefType = .{ .generation = 3, .id = 9 };

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
    var keys: InputKeysType = .{};
    keys.items[0] = try chord.parseKey("left");
    keys.items[1] = try chord.parseKey("enter");
    keys.len = 2;
    var capture: ActionRoutingCapture = .{ .lua_outcome = .{ .input = .{ .forward_binding = keys } } };
    var handler: ActionRoutingHandler = .{ .effects = capture.port() };

    _ = try handler.execute(
        .{ .lua_expr = .{ .generation = 1, .id = 2 } },
        routingAuthority(false),
    );

    try std.testing.expectEqualSlices(Event, &.{ .lua, .key, .key }, capture.events[0..capture.event_count]);
    try std.testing.expectEqualSlices(KeyType, keys.slice(), capture.keys[0..capture.key_count]);

    var paste: InputPasteType = .{};
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
    var keys: InputKeysType = .{};
    keys.items[0] = try chord.parseKey("left");
    keys.items[1] = try chord.parseKey("enter");
    keys.len = 2;
    var capture: ActionRoutingCapture = .{
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

test "agent mode suppresses configured actions before source execution" {
    const blocked = [_]action_module.Action{
        .new_tab,
        .close_pane,
        .toggle_sidebar,
        .enter_copy_mode,
        .{ .lua_callback = .{ .generation = 1, .id = 1 } },
        .{ .lua_expr = .{ .generation = 1, .id = 1 } },
        .{ .plugin = .{ .plugin = 1, .action = 1 } },
    };

    for (blocked) |action| {
        var capture: ActionRoutingCapture = .{};
        var handler: ActionRoutingHandler = .{ .effects = capture.port() };

        const control = try handler.execute(action, .{ .available = .{
            .copy_mode_active = false,
            .agent_mode_active = true,
        } });

        try std.testing.expectEqual(Control.continue_routing, control);
        try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    }
}

test "agent mode allows toggling back and detaching" {
    const authority: Authority = .{ .available = .{
        .copy_mode_active = false,
        .agent_mode_active = true,
    } };
    var capture: ActionRoutingCapture = .{};
    var handler: ActionRoutingHandler = .{ .effects = capture.port() };

    try std.testing.expectEqual(
        Control.continue_routing,
        try handler.execute(.toggle_agent_mode, authority),
    );
    try std.testing.expectEqualSlices(Event, &.{.native}, capture.events[0..capture.event_count]);

    capture = .{ .native_control = .stop };

    try std.testing.expectEqual(Control.stop, try handler.execute(.detach, authority));
    try std.testing.expectEqualSlices(Event, &.{.native}, capture.events[0..capture.event_count]);
}
