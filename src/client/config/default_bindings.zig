//! Built-in keymap, kept declarative and separate from input dispatch.

const GenericBinding = @import("../input/GenericBinding.zig").Type;
const ActionType = @import("../input/action.zig").Action;
const config_model = @import("model.zig");
const KeyType = @import("../input/Key.zig");
const Resolved = @import("Resolved.zig");
const GenericKeymap = @import("../input/GenericKeymap.zig").Type;
const parseKey_module = @import("../input/chord.zig").parseKey;
const std = @import("std");

pub const count = 42;
pub const Binding = GenericBinding(ActionType, config_model.max_binding_keys);

pub fn load(prefix: KeyType) ![count]Binding {
    return .{
        try prefixed(prefix, "a", .toggle_thread_view),

        try prefixed(prefix, "-", .{ .scroll_pane = .up }),
        try prefixed(prefix, "=", .{ .scroll_pane = .down }),

        try prefixed(prefix, "%", .{ .split_pane = .horizontal }),
        try prefixed(prefix, "\"", .{ .split_pane = .vertical }),

        try prefixed(prefix, "left", .{ .focus_pane = .left }),
        try prefixed(prefix, "right", .{ .focus_pane = .right }),
        try prefixed(prefix, "up", .{ .focus_pane = .up }),
        try prefixed(prefix, "down", .{ .focus_pane = .down }),

        try prefixed(prefix, "shift+left", .{ .resize_pane = .left }),
        try prefixed(prefix, "shift+right", .{ .resize_pane = .right }),
        try prefixed(prefix, "shift+up", .{ .resize_pane = .up }),
        try prefixed(prefix, "shift+down", .{ .resize_pane = .down }),

        try prefixed(prefix, "z", .toggle_pane_fullscreen),

        try prefixed(prefix, "s", .toggle_sidebar),

        try prefixed(prefix, "alt+left", .{ .resize_sidebar = .left }),
        try prefixed(prefix, "alt+right", .{ .resize_sidebar = .right }),

        try prefixed(prefix, "w", .toggle_workspace_list),

        try prefixed(prefix, "N", .new_workspace),

        try prefixed(prefix, "W", .rename_workspace),

        try prefixed(prefix, "x", .close_pane),

        try prefixed(prefix, "d", .detach),

        try prefixed(prefix, "[", .enter_copy_mode),

        try prefixed(prefix, "g", .goto_picker),

        try prefixed(prefix, "/", .history_palette),

        try prefixed(prefix, "?", .suggest_command),

        try prefixed(prefix, "c", .new_tab),

        try prefixed(prefix, "n", .{ .select_tab_offset = 1 }),
        try prefixed(prefix, "p", .{ .select_tab_offset = -1 }),

        try prefixed(prefix, "1", .{ .select_tab = 0 }),
        try prefixed(prefix, "2", .{ .select_tab = 1 }),
        try prefixed(prefix, "3", .{ .select_tab = 2 }),
        try prefixed(prefix, "4", .{ .select_tab = 3 }),
        try prefixed(prefix, "5", .{ .select_tab = 4 }),
        try prefixed(prefix, "6", .{ .select_tab = 5 }),
        try prefixed(prefix, "7", .{ .select_tab = 6 }),
        try prefixed(prefix, "8", .{ .select_tab = 7 }),
        try prefixed(prefix, "9", .{ .select_tab = 8 }),

        try prefixed(prefix, "T", .rename_tab),
        try prefixed(prefix, "X", .close_tab),

        try prefixed(prefix, ",", .{ .move_tab = .previous }),
        try prefixed(prefix, ".", .{ .move_tab = .next }),
    };
}

/// Builds the effective keymap. Explicit bindings keep their order and
/// replace every default they conflict with — same sequence, or one a prefix
/// of the other. Dropping prefix conflicts too keeps the merged keymap free
/// of the ambiguity the router rejects; every other default is appended.
pub fn resolve(prefix: KeyType, configured: []const Binding) !Resolved {
    if (configured.len > config_model.max_bindings) {
        return error.TooManyBindings;
    }

    var resolved: Resolved = .{};
    @memcpy(resolved.bindings[0..configured.len], configured);
    resolved.len = @intCast(configured.len);

    const defaults = try load(prefix);
    for (&defaults) |*default| {
        var overridden = false;
        for (configured) |*binding| {
            if (binding.conflictsWith(default)) {
                overridden = true;
                break;
            }
        }
        if (overridden) {
            continue;
        }
        if (resolved.len == config_model.max_bindings) {
            return error.TooManyBindings;
        }
        resolved.bindings[resolved.len] = default.*;
        resolved.len += 1;
    }

    return resolved;
}

/// Proves the merged keymap compiles with the same parameters the client's
/// router uses. `telar config check` calls this so a merge that the router
/// would reject fails here instead of at interactive startup.
pub fn validate(prefix: KeyType, configured: []const Binding) !void {
    const resolved = try resolve(prefix, configured);
    _ = try GenericKeymap(ActionType, config_model.max_bindings, config_model.max_binding_keys)
        .init(resolved.slice());
}

fn prefixed(prefix: KeyType, suffix: []const u8, action_value: ActionType) !Binding {
    return .init(&.{ prefix, try parseKey_module(suffix) }, action_value);
}

test "agent mode toggle uses configured prefix key and allow for overrides" {
    const testing = std.testing;
    const prefix = try parseKey_module("ctrl+s");
    const expected = try prefixed(prefix, "a", .toggle_thread_view);
    const resolved = try resolve(prefix, &.{});
    var found: usize = 0;

    for (resolved.slice()) |*binding| {
        if (binding.sameSequence(&expected)) {
            try testing.expectEqualDeep(expected.action, binding.action);
            found += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), found);

    try validate(prefix, &.{});

    const replacement = try prefixed(prefix, "a", .detach);
    const overridden = try resolve(prefix, &.{replacement});
    found = 0;

    for (overridden.slice()) |*binding| {
        if (binding.sameSequence(&replacement)) {
            try testing.expectEqualDeep(replacement.action, binding.action);
            found += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), found);
    try validate(prefix, &.{replacement});
}

test "focused scroll defaults use the configured prefix and can be overridden" {
    const testing = std.testing;
    const prefix = try parseKey_module("ctrl+s");
    const up = try prefixed(prefix, "-", .{ .scroll_pane = .up });
    const down = try prefixed(prefix, "=", .{ .scroll_pane = .down });
    const defaults = try resolve(prefix, &.{});
    var found: usize = 0;

    for (defaults.slice()) |*binding| {
        if (binding.sameSequence(&up) or binding.sameSequence(&down)) {
            try testing.expectEqualDeep(if (binding.sameSequence(&up)) up.action else down.action, binding.action);
            found += 1;
        }
    }

    try testing.expectEqual(@as(usize, 2), found);
    const override = try prefixed(prefix, "-", .toggle_sidebar);
    const resolved = try resolve(prefix, &.{override});
    try testing.expectEqual(@as(usize, count), resolved.slice().len);
    try testing.expectEqualDeep(override.action, resolved.bindings[0].action);
    try validate(prefix, &.{override});
}

test "configured bindings extend defaults and override matching sequences" {
    const testing = std.testing;
    const prefix = try parseKey_module("ctrl+s");
    const override = try prefixed(prefix, "s", .detach);
    const global = try Binding.parse(&.{"ctrl+d"}, .detach);

    const resolved = try resolve(prefix, &.{ override, global });

    try testing.expectEqual(@as(usize, count + 1), resolved.slice().len);
    try testing.expect(resolved.bindings[0].sameSequence(&override));
    try testing.expectEqualDeep(ActionType.detach, resolved.bindings[0].action);
    try testing.expect(resolved.bindings[1].sameSequence(&global));

    var matching_defaults: usize = 0;
    for (resolved.slice()) |*binding| {
        if (binding.sameSequence(&override)) {
            matching_defaults += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), matching_defaults);
}

test "a configured binding evicts every default it prefix-conflicts with" {
    const testing = std.testing;
    const prefix = try parseKey_module("ctrl+b");
    // Extends the default `<prefix> s` (toggle_sidebar) by one key. The
    // default must be dropped, or the merged keymap is prefix-ambiguous.
    const extended = try Binding.init(
        &.{ prefix, try parseKey_module("s"), try parseKey_module("x") },
        .detach,
    );
    const shadowed = try prefixed(prefix, "s", .toggle_sidebar);

    const resolved = try resolve(prefix, &.{extended});

    try testing.expectEqual(@as(usize, count), resolved.slice().len);
    for (resolved.slice()) |*binding| {
        try testing.expect(!binding.sameSequence(&shadowed));
    }
    try validate(prefix, &.{extended});
}

test "validating rejects configured bindings that conflict with each other" {
    const testing = std.testing;
    const prefix = try parseKey_module("ctrl+b");
    const short = try prefixed(prefix, "g", .toggle_sidebar);
    const long = try Binding.init(
        &.{ prefix, try parseKey_module("g"), try parseKey_module("x") },
        .detach,
    );

    try testing.expectError(error.AmbiguousBindingPrefix, validate(prefix, &.{ short, long }));
}

test "resolving bindings enforces the router capacity" {
    const testing = std.testing;
    const prefix = try parseKey_module("ctrl+s");
    const configured = try Binding.parse(&.{"ctrl+d"}, .detach);
    const bindings: [config_model.max_bindings]Binding = @splat(configured);

    try testing.expectError(error.TooManyBindings, resolve(prefix, &bindings));
}
