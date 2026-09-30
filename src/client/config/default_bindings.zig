//! Built-in keymap, kept declarative and separate from input dispatch.
const keyinput = @import("keyinput");

const data = @import("model");
const Resolved = @import("Resolved.zig");
const GenericKeymap = keyinput.GenericKeymap;
const std = @import("std");

pub const count = 43;
pub const Binding = keyinput.GenericBinding(data.Action, data.config_values.max_binding_keys);

pub fn load(prefix: keyinput.Key) ![count]Binding {
    return .{
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
        // Back from a worktree's tabs to its project.
        try prefixed(prefix, "u", .leave_worktree),

        try prefixed(prefix, "N", .new_workspace),

        try prefixed(prefix, "W", .rename_workspace),

        try prefixed(prefix, "x", .close_pane),

        try prefixed(prefix, "d", .detach),

        try prefixed(prefix, "[", .enter_copy_mode),

        try prefixed(prefix, "g", .goto_picker),

        try prefixed(prefix, "/", .history_palette),

        try prefixed(
            prefix,
            "f",
            .path_picker,
        ),

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
/// of the ambiguity the router rejects; every other default is appended
/// while the keymap has room, and `Resolved.dropped` counts the rest, so a
/// full keymap never stops the window from starting.
pub fn resolve(prefix: keyinput.Key, configured: []const Binding) !Resolved {
    var resolved: Resolved = .{};
    const kept = configured[0..@min(configured.len, data.config_values.max_bindings)];
    @memcpy(resolved.bindings[0..kept.len], kept);
    resolved.len = @intCast(kept.len);
    resolved.dropped = @intCast(configured.len - kept.len);

    const defaults = try load(prefix);
    for (&defaults) |*default| {
        if (overridden(default, configured)) {
            continue;
        }

        if (resolved.len == data.config_values.max_bindings) {
            resolved.dropped += 1;
            continue;
        }

        resolved.bindings[resolved.len] = default.*;
        resolved.len += 1;
    }

    return resolved;
}

/// How many bindings, configured or default, the keymap for `configured`
/// has no room for; `resolve` leaves exactly these out.
///
/// ```zig
/// if (try default_bindings.surplus(prefix, bindings) != 0) report(...);
/// ```
pub fn surplus(prefix: keyinput.Key, configured: []const Binding) !usize {
    const defaults = try load(prefix);
    var wanted = configured.len;
    for (&defaults) |*default| {
        if (!overridden(default, configured)) {
            wanted += 1;
        }
    }

    return wanted -| data.config_values.max_bindings;
}

fn overridden(default: *const Binding, configured: []const Binding) bool {
    for (configured) |*binding| {
        if (binding.conflictsWith(default)) {
            return true;
        }
    }

    return false;
}

/// Proves the merged keymap compiles with the same parameters the client's
/// router uses. `telar config check` calls this so a merge that the router
/// would reject fails here instead of at interactive startup.
pub fn validate(prefix: keyinput.Key, configured: []const Binding) !void {
    const resolved = try resolve(prefix, configured);
    _ = try GenericKeymap(data.Action, data.config_values.max_bindings, data.config_values.max_binding_keys)
        .init(resolved.slice());
}

fn prefixed(prefix: keyinput.Key, suffix: []const u8, action_value: data.Action) !Binding {
    return .init(&.{ prefix, try keyinput.chord.parseKey(suffix) }, action_value);
}

test "focused scroll defaults use the configured prefix and can be overridden" {
    const testing = std.testing;
    const prefix = try keyinput.chord.parseKey("ctrl+s");
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
    const prefix = try keyinput.chord.parseKey("ctrl+s");
    const override = try prefixed(prefix, "s", .detach);
    const global = try Binding.parse(&.{"ctrl+d"}, .detach);

    const resolved = try resolve(prefix, &.{ override, global });

    try testing.expectEqual(@as(usize, count + 1), resolved.slice().len);
    try testing.expect(resolved.bindings[0].sameSequence(&override));
    try testing.expectEqualDeep(data.Action.detach, resolved.bindings[0].action);
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
    const prefix = try keyinput.chord.parseKey("ctrl+b");
    // Extends the default `<prefix> s` (toggle_sidebar) by one key. The
    // default must be dropped, or the merged keymap is prefix-ambiguous.
    const extended = try Binding.init(
        &.{ prefix, try keyinput.chord.parseKey("s"), try keyinput.chord.parseKey("x") },
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
    const prefix = try keyinput.chord.parseKey("ctrl+b");
    const short = try prefixed(prefix, "g", .toggle_sidebar);
    const long = try Binding.init(
        &.{ prefix, try keyinput.chord.parseKey("g"), try keyinput.chord.parseKey("x") },
        .detach,
    );

    try testing.expectError(error.AmbiguousBindingPrefix, validate(prefix, &.{ short, long }));
}

test "a full keymap keeps the configured bindings and leaves out the defaults it has no room for" {
    const testing = std.testing;
    const prefix = try keyinput.chord.parseKey("ctrl+s");
    const configured = try Binding.parse(&.{"ctrl+d"}, .detach);
    const bindings: [data.config_values.max_bindings - 1]Binding = @splat(configured);

    const resolved = try resolve(prefix, &bindings);
    try testing.expectEqual(@as(u16, data.config_values.max_bindings), resolved.len);
    try testing.expectEqualDeep(configured.action, resolved.bindings[bindings.len - 1].action);
    try testing.expectEqual(@as(u16, count - 1), resolved.dropped);
    try testing.expectEqual(@as(usize, count - 1), try surplus(prefix, &bindings));
    try testing.expectEqual(@as(usize, 0), try surplus(prefix, bindings[0 .. data.config_values.max_bindings - count]));
}
